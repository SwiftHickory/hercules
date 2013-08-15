/* -*- C -*- */

/* @copyright_notice_start
 *
 * This file is part of the CMU Hercules ground motion simulator developed
 * by the CMU Quake project.
 *
 * Copyright (C) Carnegie Mellon University. All rights reserved.
 *
 * This program is covered by the terms described in the 'LICENSE.txt' file
 * included with this software package.
 *
 * This program comes WITHOUT ANY WARRANTY; without even the implied warranty
 * of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * 'LICENSE.txt' file for more details.
 *
 *  @copyright_notice_end
 */

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "psolve.h"
#include "kernel.h"
#include "quake_util.h"

#include <cuda.h>
#include <cuda_runtime.h>


/**
 * For regular simulations use 1e-20.  For performance and scalability,
 * uncomment the immediate return in vector_is_zero() and vector_is_all_zero().
 * Alternatives with each platform underflow precision limit for 'double'
 * may also work, though this have not been thoroughly tested.
 *
 * Known underflow limits:
 * - NICS' Kraken: Limit is ~2.2e-308 --> use 1e-200
 *
 */
#define UNDERFLOW_CAP_STIFFNESS 1e-20


int32_t gpu_get_blocksize(gpu_spec_t *gpuSpecs, char* kernel)
{
    cudaFuncAttributes attributes;
    cudaFuncGetAttributes(&attributes, kernel);

    int computed = gpuSpecs->regs_per_block / attributes.numRegs;
    computed = 1 << (int)floor(log(computed)/log(2));

    return(imin(computed, gpuSpecs->max_threads));
}


__global__  void kernelInitReverseLookup(gpu_data_t *gpuDataDevice)
{
    int       i;
    int32_t   lnid = (blockIdx.x * blockDim.x) + threadIdx.x; 
    elem_t*   elemp;
    int32_t   eindex;

    /* Since number of nodes may not be exactly divisible by block size,
       check that we are not off the end of the node array */
    if (lnid >= gpuDataDevice->nharbored) {
      return;
    }

    rev_entry_t *tableEntry = &(gpuDataDevice->reverseLookupDevice[lnid]);

    memset(tableEntry, 0, sizeof(rev_entry_t));
    
    /* loop on the number of elements */
    for (eindex = 0; eindex < gpuDataDevice->lenum; eindex++) {      
      elemp  = &(gpuDataDevice->elemTableDevice[eindex]);
      
      for (i = 0; i < 8; i++) {
	if (lnid == elemp->lnid[i]) {
	  tableEntry->lf_indices[tableEntry->elemnum].index = eindex*8 + i;
	  (tableEntry->elemnum)++;
	}
      }
    }
}


__global__  void kernelInitLinearLookup(gpu_data_t *gpuDataDevice,
					int32_t    myLinearElementsCount,
					int32_t*   myLinearElementsMapperDevice,
					rev_entry_t* reverseLookupLinearDevice)
{
    int       i;
    int32_t   lnid = (blockIdx.x * blockDim.x) + threadIdx.x; 
    int32_t   lin_eindex;
    elem_t*   elemp;
    int32_t   eindex;

    /* Since number of nodes may not be exactly divisible by block size,
       check that we are not off the end of the node array */
    if (lnid >= gpuDataDevice->nharbored) {
      return;
    }

    rev_entry_t *tableEntry = &(reverseLookupLinearDevice[lnid]);

    memset(tableEntry, 0, sizeof(rev_entry_t));
    
    /* loop on the number of elements */
    for (lin_eindex = 0; lin_eindex < myLinearElementsCount; lin_eindex++) {
      
      eindex = myLinearElementsMapperDevice[lin_eindex];
      elemp  = &(gpuDataDevice->elemTableDevice[eindex]);
      
      for (i = 0; i < 8; i++) {
	if (lnid == elemp->lnid[i]) {
	  tableEntry->lf_indices[tableEntry->elemnum].index = lin_eindex*8 + i;
	  (tableEntry->elemnum)++;
	}
      }
    }
}


/* Stiffness Calc-Force Kernel */
__global__ void kernelStiffnessCalcLocal(gpu_data_t *gpuDataDevice,
					 int32_t   myLinearElementsCount,
					 int32_t*  myLinearElementsMapperDevice)
{
    int       i;
    int32_t   eindex;
    int32_t   lin_eindex = (blockIdx.x * blockDim.x) + threadIdx.x; 
    fvector_t curDisp[8];

    register fvector_t localForceReg[8];
    register int32_t   lnidReg[8];
    register e_t       eTableReg;

    /* Since number of elements may not be exactly divisible by block size,
       check that we are not off the end of the element array */
    if (lin_eindex >= myLinearElementsCount) {
      return;
    }

    eindex = myLinearElementsMapperDevice[lin_eindex];
  
    /* Copy node ids and constants from global mem to registers */
    memcpy(lnidReg, gpuDataDevice->elemTableDevice[eindex].lnid, 
	   8*sizeof(int32_t));
    memcpy(&eTableReg, &(gpuDataDevice->eTableDevice[eindex]), sizeof(e_t));
  
    /* Get current displacements */
    for (i = 0; i < 8; i++) {
      memcpy(&(curDisp[i]), gpuDataDevice->tm1Device + lnidReg[i], 
	     sizeof(fvector_t));
    }
    
    /* Coefficients for new stiffness matrix calculation */
    if (vector_is_zero( curDisp ) != 0) {
      
      double first_coeff  = -0.5625 * (eTableReg.c2 + 2 * eTableReg.c1);
      double second_coeff = -0.5625 * (eTableReg.c2);
      double third_coeff  = -0.5625 * (eTableReg.c1);
      
      double atu[24];
      double firstVec[24];
      
      aTransposeU( curDisp, atu );
      firstVector( atu, firstVec, first_coeff, second_coeff, third_coeff );
      au( localForceReg, firstVec );
    }

    /* Copy local forces from registers to global mem */
    memcpy(&(gpuDataDevice->localForceDevice[lin_eindex*8]), localForceReg, 
	     8*sizeof(fvector_t));
}


/* Damping Calc-Conv Kernel */
__global__  void kernelDampingCalcConv(gpu_data_t* gpuDataDevice,
				       double rmax) 
{
  int i;
  int32_t   eindex = (blockIdx.x * blockDim.x) + threadIdx.x;
  
  /* Since number of elements may not be exactly divisible by block size,
     check that we are not off the end of the element array */
  if (eindex >= gpuDataDevice->lenum) {
    return;
  }
  
  elem_t *elemp;
  edata_t *edata;
  
  elemp = &gpuDataDevice->elemTableDevice[eindex];
  edata = (edata_t *)elemp->data;
  
  // SHEAR RELATED CONVOLUTION
  
  if ( (edata->g0_shear != 0) && (edata->g1_shear != 0) ) {
    
    double c0_shear = edata->g0_shear;
    double c1_shear = edata->g1_shear;
    
    double g0_shear = c0_shear * rmax;
    double g1_shear = c1_shear * rmax;
    
    double coef_shear_1 = g0_shear / 2.;
    double coef_shear_2 = coef_shear_1 * ( 1. - g0_shear );
    
    double coef_shear_3 = g1_shear / 2.;
    double coef_shear_4 = coef_shear_3 * ( 1. - g1_shear );
    
    double exp_coef_shear_0 = exp( -g0_shear );
    double exp_coef_shear_1 = exp( -g1_shear );
    
    for(i = 0; i < 8; i++)
      {
	int32_t     lnid, cindex;
	fvector_t   *f0_tm1, *f1_tm1, *tm1Disp, *tm2Disp;
	
	lnid = elemp->lnid[i];
	
	/* cindex is the index of the node in the convolution vector */
	cindex = eindex * 8 + i;
	
	tm1Disp = gpuDataDevice->tm1Device + lnid;
	tm2Disp = gpuDataDevice->tm2Device + lnid;
	
	f0_tm1 = gpuDataDevice->conv_shear_1Device + cindex;
	f1_tm1 = gpuDataDevice->conv_shear_2Device + cindex;
	
	f0_tm1->f[0] = coef_shear_2 * tm1Disp->f[0] + coef_shear_1 * tm2Disp->f[0] + exp_coef_shear_0 * f0_tm1->f[0];
	f0_tm1->f[1] = coef_shear_2 * tm1Disp->f[1] + coef_shear_1 * tm2Disp->f[1] + exp_coef_shear_0 * f0_tm1->f[1];
	f0_tm1->f[2] = coef_shear_2 * tm1Disp->f[2] + coef_shear_1 * tm2Disp->f[2] + exp_coef_shear_0 * f0_tm1->f[2];
	
	f1_tm1->f[0] = coef_shear_4 * tm1Disp->f[0] + coef_shear_3 * tm2Disp->f[0] + exp_coef_shear_1 * f1_tm1->f[0];
	f1_tm1->f[1] = coef_shear_4 * tm1Disp->f[1] + coef_shear_3 * tm2Disp->f[1] + exp_coef_shear_1 * f1_tm1->f[1];
	f1_tm1->f[2] = coef_shear_4 * tm1Disp->f[2] + coef_shear_3 * tm2Disp->f[2] + exp_coef_shear_1 * f1_tm1->f[2];
	
      } // For local nodes (0:7)
    
  } // end if null coefficients
  
  // DILATATION RELATED CONVOLUTION
  
  if ( (edata->g0_kappa != 0) && (edata->g1_kappa != 0) ) {
    
    double c0_kappa = edata->g0_kappa;
    double c1_kappa = edata->g1_kappa;
    
    double g0_kappa = c0_kappa * rmax;
    double g1_kappa = c1_kappa * rmax;
    
    double coef_kappa_1 = g0_kappa / 2.;
    double coef_kappa_2 = coef_kappa_1 * ( 1. - g0_kappa );
    
    double coef_kappa_3 = g1_kappa / 2.;
    double coef_kappa_4 = coef_kappa_3 * ( 1. - g1_kappa );
    
    double exp_coef_kappa_0 = exp( -g0_kappa );
    double exp_coef_kappa_1 = exp( -g1_kappa );
    
    for(i = 0; i < 8; i++)
      {
	int32_t     lnid, cindex;
	fvector_t   *f0_tm1, *f1_tm1, *tm1Disp, *tm2Disp;
	
	lnid = elemp->lnid[i];
	
	/* cindex is the index of the node in the convolution vector */
	cindex = eindex * 8 + i;
	
	tm1Disp = gpuDataDevice->tm1Device + lnid;
	tm2Disp = gpuDataDevice->tm2Device + lnid;
	
	f0_tm1 = gpuDataDevice->conv_kappa_1Device + cindex;
	f1_tm1 = gpuDataDevice->conv_kappa_2Device + cindex;
	
	f0_tm1->f[0] = coef_kappa_2 * tm1Disp->f[0] + coef_kappa_1 * tm2Disp->f[0] + exp_coef_kappa_0 * f0_tm1->f[0];
	f0_tm1->f[1] = coef_kappa_2 * tm1Disp->f[1] + coef_kappa_1 * tm2Disp->f[1] + exp_coef_kappa_0 * f0_tm1->f[1];
	f0_tm1->f[2] = coef_kappa_2 * tm1Disp->f[2] + coef_kappa_1 * tm2Disp->f[2] + exp_coef_kappa_0 * f0_tm1->f[2];
	
	f1_tm1->f[0] = coef_kappa_4 * tm1Disp->f[0] + coef_kappa_3 * tm2Disp->f[0] + exp_coef_kappa_1 * f1_tm1->f[0];
	f1_tm1->f[1] = coef_kappa_4 * tm1Disp->f[1] + coef_kappa_3 * tm2Disp->f[1] + exp_coef_kappa_1 * f1_tm1->f[1];
	f1_tm1->f[2] = coef_kappa_4 * tm1Disp->f[2] + coef_kappa_3 * tm2Disp->f[2] + exp_coef_kappa_1 * f1_tm1->f[2];
	
      } // For local nodes (0:7)
    
  } // end if null coefficients

  return;  
}


/* Damping Calc-force Kernel */
__global__  void kernelDampingCalcLocal(gpu_data_t* gpuDataDevice,
					double rmax) 
{
    int       i;
    int32_t   eindex = (blockIdx.x * blockDim.x) + threadIdx.x;

    fvector_t damping_vector_shear[8], damping_vector_kappa[8];

    register fvector_t localForceReg[8];
    register edata_t   eDataReg;
    register int32_t   lnidReg[8];
    register e_t       eTableReg;

    /* Since number of elements may not be exactly divisible by block size,
       check that we are not off the end of the element array */
    if (eindex >= gpuDataDevice->lenum) {
      return;
    }

    double a0_shear, a1_shear, b_shear, a0_kappa, a1_kappa, b_kappa, csum;
    
    memcpy(lnidReg, gpuDataDevice->elemTableDevice[eindex].lnid, 
	   8*sizeof(int32_t));
    memcpy(&eDataReg, gpuDataDevice->elemTableDevice[eindex].data, 
	   sizeof(edata_t)); 
    memcpy(&eTableReg, &(gpuDataDevice->eTableDevice[eindex]), sizeof(e_t));

    // SHEAR CONTRIBUTION
    a0_shear = eDataReg.a0_shear;
    a1_shear = eDataReg.a1_shear;
    b_shear  = eDataReg.b_shear;
    csum = a0_shear + a1_shear + b_shear;
    if ( csum != 0 ) {
      double coef_shear = b_shear / rmax;
      for (i = 0; i < 8; i++) {
	fvector_t *tm1Disp, *tm2Disp, *f0_tm1, *f1_tm1;
	int32_t    lnid, cindex;
	
	cindex = eindex * 8 + i;
	lnid = lnidReg[i];
	
	tm1Disp = gpuDataDevice->tm1Device + lnid;
	tm2Disp = gpuDataDevice->tm2Device + lnid;

	f0_tm1  = gpuDataDevice->conv_shear_1Device + cindex;
	f1_tm1  = gpuDataDevice->conv_shear_2Device + cindex;
	
	damping_vector_shear[i].f[0] = coef_shear * (tm1Disp->f[0] - tm2Disp->f[0])
	  - (a0_shear * f0_tm1->f[0] + a1_shear * f1_tm1->f[0])
	  + tm1Disp->f[0];
	
	damping_vector_shear[i].f[1] = coef_shear * (tm1Disp->f[1] - tm2Disp->f[1])
	  - (a0_shear * f0_tm1->f[1] + a1_shear * f1_tm1->f[1])
	  + tm1Disp->f[1];
	
	damping_vector_shear[i].f[2] = coef_shear * (tm1Disp->f[2] - tm2Disp->f[2])
	  - (a0_shear * f0_tm1->f[2] + a1_shear * f1_tm1->f[2])
	  + tm1Disp->f[2];
	
      } // end for nodes in the element
      
    } else { 
      for (i = 0; i < 8; i++) {
	fvector_t *tm1Disp;
	//fvector_t *tm2Disp;
	int32_t    lnid;
	
	lnid = lnidReg[i];
	tm1Disp = gpuDataDevice->tm1Device + lnid;
	//tm2Disp = gpuDataDevice->tm2Device + lnid;
	
	damping_vector_shear[i].f[0] = tm1Disp->f[0];
	damping_vector_shear[i].f[1] = tm1Disp->f[1];
	damping_vector_shear[i].f[2] = tm1Disp->f[2];
	
      } // end for nodes in the element
      
    } // end if for coefficients
    
    // DILATATION CONTRIBUTION
    a0_kappa   = eDataReg.a0_kappa;
    a1_kappa   = eDataReg.a1_kappa;
    b_kappa    = eDataReg.b_kappa;
    csum = a0_kappa + a1_kappa + b_kappa;
    if ( csum != 0 ) {
      double coef_kappa = b_kappa / rmax;
      
      for (i = 0; i < 8; i++) {
	fvector_t *tm1Disp, *tm2Disp, *f0_tm1, *f1_tm1;
	int32_t    lnid, cindex;
	
	cindex = eindex * 8 + i;
	lnid = lnidReg[i];
	
	tm1Disp = gpuDataDevice->tm1Device + lnid;
	tm2Disp = gpuDataDevice->tm2Device + lnid;
	
	f0_tm1  = gpuDataDevice->conv_kappa_1Device + cindex;
	f1_tm1  = gpuDataDevice->conv_kappa_2Device + cindex;

	damping_vector_kappa[i].f[0] = coef_kappa * (tm1Disp->f[0] - tm2Disp->f[0])
	  - (a0_kappa * f0_tm1->f[0] + a1_kappa * f1_tm1->f[0])
	  + tm1Disp->f[0];
	
	damping_vector_kappa[i].f[1] = coef_kappa * (tm1Disp->f[1] - tm2Disp->f[1])
	  - (a0_kappa * f0_tm1->f[1] + a1_kappa * f1_tm1->f[1])
	  + tm1Disp->f[1];
	
	damping_vector_kappa[i].f[2] = coef_kappa * (tm1Disp->f[2] - tm2Disp->f[2])
	  - (a0_kappa * f0_tm1->f[2] + a1_kappa * f1_tm1->f[2])
	  + tm1Disp->f[2];
	
      } // end for nodes in the element
      
    } else {
      for (i = 0; i < 8; i++) {
	fvector_t *tm1Disp;
	//fvector_t *tm2Disp;
	int32_t    lnid;
	
	lnid = lnidReg[i];
	tm1Disp = gpuDataDevice->tm1Device + lnid;
	//tm2Disp = gpuDataDevice->tm2Device + lnid;
	
	damping_vector_kappa[i].f[0] = tm1Disp->f[0];
	damping_vector_kappa[i].f[1] = tm1Disp->f[1];
	damping_vector_kappa[i].f[2] = tm1Disp->f[2];

      } // end for nodes in the element
      
    } // end if for coefficients
    
    double kappa = -0.5625 * (eTableReg.c2 + 2. / 3. * eTableReg.c1);
    double mu = -0.5625 * eTableReg.c1;
    
    double atu[24];
    double firstVec[24];
    
    memset(firstVec, 0, 24*sizeof(double));

    //fvector_t* localForce = gpuDataDevice->localForceDevice + (eindex*8);
    //memset(localForce, 0, 8 * sizeof(fvector_t));

    if(vector_is_zero( damping_vector_shear ) != 0) {
      aTransposeU( damping_vector_shear, atu );
      firstVector_mu( atu, firstVec, mu);
    }
    
    if(vector_is_zero( damping_vector_kappa ) != 0) {
      aTransposeU( damping_vector_kappa, atu );
      firstVector_kappa( atu, firstVec, kappa);
    }
    
    au( localForceReg, firstVec );

    /* Copy local forces from registers to global mem */
    memcpy(&(gpuDataDevice->localForceDevice[eindex*8]), localForceReg, 
	     8*sizeof(fvector_t));
    return;
}


/* Add forces Kernel */
__global__  void kernelAddLocalForces(gpu_data_t *gpuDataDevice)
{
    int          i;
    int32_t      lnid = (blockIdx.x * blockDim.x) + threadIdx.x; 

    fvector_t*            localForce;
    register rev_entry_t  revReg;
    register fvector_t    nodalForceReg;

    /* Since number of nodes may not be exactly divisible by block size,
       check that we are not off the end of the node array */
    if (lnid >= gpuDataDevice->nharbored) {
      return;
    }

    /* Copy reverse lookup table from global to register */
    memcpy(&revReg, (gpuDataDevice->reverseLookupDevice) + lnid, 
	   sizeof(rev_entry_t));

    /* Copy nodal force from global to register */
    memcpy(&nodalForceReg, (gpuDataDevice->forceDevice) + lnid, 
	   sizeof(fvector_t));

    /* Update forces for this node */
    for (i = 0; i < revReg.elemnum; i++) {
      localForce = &(gpuDataDevice->localForceDevice[revReg.lf_indices[i].index]);

      nodalForceReg.f[0] += localForce->f[0];
      nodalForceReg.f[1] += localForce->f[1];
      nodalForceReg.f[2] += localForce->f[2];
    }

    /* Copy updated nodal force from register to global */
    memcpy((gpuDataDevice->forceDevice) + lnid, &nodalForceReg, 
	   sizeof(fvector_t));
}


/* -------------------------------------------------------------------------- */
/*                         Efficient Method Utilities                         */
/* -------------------------------------------------------------------------- */


/**
 * For effective stiffness method:
 *
 * Check whether all components of a 3D vector are close to zero,
 * i.e., less than a small threshold.
 *
 * \return 1 when there is at least one "non-zero" component;
 *         0 when all the components are "zero".
 */
__host__ __device__ int vector_is_zero( const fvector_t* v )
{
    /*
     * For scalability studies, uncomment the immediate return.
     */

    /* return 1; */

    int i,j;

    for (i = 0; i < 8; i++) {
        for(j = 0; j < 3; j++){
            if (fabs( v[i].f[j] ) > UNDERFLOW_CAP_STIFFNESS) {
                return 1;
            }
        }
    }

    return 0;
}


__host__ __device__ void aTransposeU( fvector_t* un, double* atu )
{
    double temp[24];
    double u[24];
    int    i, j;

    /* arrange displacement values in an array */
    for (i=0; i<8; i++) {
        for(j=0; j<3; j++) {
            temp[i*3 + j] = un[i].f[j];     /* u1 u2 u3 .... v1 v2 v3 ... z1 z2 z3 */
	}
    }

    reformU( temp, u );

    /* atu[0] = u[0] + u[1] + u[2] + u[3] + u[4] + u[5] + u[6] + u[7]; */
    atu[0]  = 0;
    atu[1]  = -u[0] - u[1] - u[2] - u[3] + u[4] + u[5] + u[6] + u[7];
    atu[2]  = -u[0] - u[1] + u[2] + u[3] - u[4] - u[5] + u[6] + u[7];
    atu[3]  = -u[0] + u[1] - u[2] + u[3] - u[4] + u[5] - u[6] + u[7];
    atu[4]  =  u[0] + u[1] - u[2] - u[3] - u[4] - u[5] + u[6] + u[7];
    atu[5]  =  u[0] - u[1] + u[2] - u[3] - u[4] + u[5] - u[6] + u[7];
    atu[6]  =  u[0] - u[1] - u[2] + u[3] + u[4] - u[5] - u[6] + u[7];
    atu[7]  = -u[0] + u[1] + u[2] - u[3] + u[4] - u[5] - u[6] + u[7];

    /* atu[8] = u[8] + u[9] + u[10] + u[11] + u[12] + u[13] + u[14] + u[15]; */
    atu[8]  = 0;
    atu[9]  = -u[8] - u[9] - u[10] - u[11] + u[12] + u[13] + u[14] + u[15];
    atu[10] = -u[8] - u[9] + u[10] + u[11] - u[12] - u[13] + u[14] + u[15];
    atu[11] = -u[8] + u[9] - u[10] + u[11] - u[12] + u[13] - u[14] + u[15];
    atu[12] =  u[8] + u[9] - u[10] - u[11] - u[12] - u[13] + u[14] + u[15];
    atu[13] =  u[8] - u[9] + u[10] - u[11] - u[12] + u[13] - u[14] + u[15];
    atu[14] =  u[8] - u[9] - u[10] + u[11] + u[12] - u[13] - u[14] + u[15];
    atu[15] = -u[8] + u[9] + u[10] - u[11] + u[12] - u[13] - u[14] + u[15];

    /* atu[16] = u[16] + u[17] + u[18] + u[19] + u[20] + u[21] + u[22] + u[23]; */
    atu[16] = 0;
    atu[17] = -u[16] - u[17] - u[18] - u[19] + u[20] + u[21] + u[22] + u[23];
    atu[18] = -u[16] - u[17] + u[18] + u[19] - u[20] - u[21] + u[22] + u[23];
    atu[19] = -u[16] + u[17] - u[18] + u[19] - u[20] + u[21] - u[22] + u[23];
    atu[20] =  u[16] + u[17] - u[18] - u[19] - u[20] - u[21] + u[22] + u[23];
    atu[21] =  u[16] - u[17] + u[18] - u[19] - u[20] + u[21] - u[22] + u[23];
    atu[22] =  u[16] - u[17] - u[18] + u[19] + u[20] - u[21] - u[22] + u[23];
    atu[23] = -u[16] + u[17] + u[18] - u[19] + u[20] - u[21] - u[22] + u[23];
}

__host__ __device__ void firstVector( const double* atu, 
				      double* finalVector, 
				      double a, 
				      double c, 
				      double b )
{
    finalVector[0] = 0;
    finalVector[1] = b * (atu[19] + atu[1]);
    finalVector[2] = b * (atu[11] + atu[2]);
    finalVector[3] = a * atu[3] + c * (atu[10] + atu[17]);
    finalVector[4] = b * (atu[13] + atu[22] + 2. * atu[4]) / 3.;
    finalVector[5] = ( (a + b) * atu[5] + c * atu[12] ) /3.;
    finalVector[6] = ( (a + b) * atu[6] + c * atu[20] ) /3.;
    finalVector[7] = ( (a + 2.*b) * atu[7] ) / 9.;

    finalVector[8] = 0;
    finalVector[9] = b * (atu[18] + atu[9]);
    finalVector[10] = a * atu[10] + c * (atu[3] + atu[17]);
    finalVector[11] = b * (atu[11] + atu[2]);
    finalVector[12] = ( (a + b) * atu[12] + c * atu[5] ) / 3.;
    finalVector[13] = b * (atu[4] + atu[22] + 2. * atu[13]) / 3.;
    finalVector[14] = ( (a + b) * atu[14] + c * atu[21] ) /3.;
    finalVector[15] = (a + 2. * b) * atu[15] / 9.;

    finalVector[16] = 0;
    finalVector[17] = a * atu[17] + c * (atu[3] + atu[10]);
    finalVector[18] = b * (atu[18] + atu[9]);
    finalVector[19] = b * (atu[19] + atu[1]);
    finalVector[20] = ( (a + b) * atu[20] + c * atu[6] ) / 3.;
    finalVector[21] = ( (a + b) * atu[21] + c * atu[14] ) / 3.;
    finalVector[22] = b * ( atu[4] + atu[13] + 2. * atu[22]) / 3.;
    finalVector[23] = (a + 2. * b) * atu[23] / 9.;
}


__host__ __device__ void au( fvector_t* resVec, const double* u )
{
    int    i, j;
    double finVec[24];
    double temp[24];


    finVec[0]  = u[0]  - u[1] - u[2] - u[3] + u[4] + u[5] + u[6] - u[7];
    finVec[1]  = u[0]  - u[1] - u[2] + u[3] + u[4] - u[5] - u[6] + u[7];
    finVec[2]  = u[0]  - u[1] + u[2] - u[3] - u[4] + u[5] - u[6] + u[7];
    finVec[3]  = u[0]  - u[1] + u[2] + u[3] - u[4] - u[5] + u[6] - u[7];
    finVec[4]  = u[0]  + u[1] - u[2] - u[3] - u[4] - u[5] + u[6] + u[7];
    finVec[5]  = u[0]  + u[1] - u[2] + u[3] - u[4] + u[5] - u[6] - u[7];
    finVec[6]  = u[0]  + u[1] + u[2] - u[3] + u[4] - u[5] - u[6] - u[7];
    finVec[7]  = u[0]  + u[1] + u[2] + u[3] + u[4] + u[5] + u[6] + u[7];

    finVec[8]  = u[8]  - u[9] - u[10] - u[11] + u[12] + u[13] + u[14] - u[15];
    finVec[9]  = u[8]  - u[9] - u[10] + u[11] + u[12] - u[13] - u[14] + u[15];
    finVec[10] = u[8]  - u[9] + u[10] - u[11] - u[12] + u[13] - u[14] + u[15];
    finVec[11] = u[8]  - u[9] + u[10] + u[11] - u[12] - u[13] + u[14] - u[15];
    finVec[12] = u[8]  + u[9] - u[10] - u[11] - u[12] - u[13] + u[14] + u[15];
    finVec[13] = u[8]  + u[9] - u[10] + u[11] - u[12] + u[13] - u[14] - u[15];
    finVec[14] = u[8]  + u[9] + u[10] - u[11] + u[12] - u[13] - u[14] - u[15];
    finVec[15] = u[8]  + u[9] + u[10] + u[11] + u[12] + u[13] + u[14] + u[15];

    finVec[16] = u[16] - u[17] - u[18] - u[19] + u[20] + u[21] + u[22] - u[23];
    finVec[17] = u[16] - u[17] - u[18] + u[19] + u[20] - u[21] - u[22] + u[23];
    finVec[18] = u[16] - u[17] + u[18] - u[19] - u[20] + u[21] - u[22] + u[23];
    finVec[19] = u[16] - u[17] + u[18] + u[19] - u[20] - u[21] + u[22] - u[23];
    finVec[20] = u[16] + u[17] - u[18] - u[19] - u[20] - u[21] + u[22] + u[23];
    finVec[21] = u[16] + u[17] - u[18] + u[19] - u[20] + u[21] - u[22] - u[23];
    finVec[22] = u[16] + u[17] + u[18] - u[19] + u[20] - u[21] - u[22] - u[23];
    finVec[23] = u[16] + u[17] + u[18] + u[19] + u[20] + u[21] + u[22] + u[23];

    reformF( finVec, temp );

    for (j = 0; j<8; j++)
    {
        for (i = 0; i<3; i++)
        {
            resVec[j].f[i] += temp[j*3 + i];
        }
    }
}


__host__ __device__ void reformF( const double* u, double* newU )
{
    newU[0]  = u[0];
    newU[1]  = u[8];
    newU[2]  = u[16];
    newU[3]  = u[1];
    newU[4]  = u[9];
    newU[5]  = u[17];
    newU[6]  = u[2];
    newU[7]  = u[10];
    newU[8]  = u[18];
    newU[9]  = u[3];
    newU[10] = u[11];
    newU[11] = u[19];
    newU[12] = u[4];
    newU[13] = u[12];
    newU[14] = u[20];
    newU[15] = u[5];
    newU[16] = u[13];
    newU[17] = u[21];
    newU[18] = u[6];
    newU[19] = u[14];
    newU[20] = u[22];
    newU[21] = u[7];
    newU[22] = u[15];
    newU[23] = u[23];
}

__host__ __device__ void reformU( const double* u, double* newU )
{
    newU[0]  = u[0];
    newU[1]  = u[3];
    newU[2]  = u[6];
    newU[3]  = u[9];
    newU[4]  = u[12];
    newU[5]  = u[15];
    newU[6]  = u[18];
    newU[7]  = u[21];
    newU[8]  = u[1];
    newU[9]  = u[4];
    newU[10] = u[7];
    newU[11] = u[10];
    newU[12] = u[13];
    newU[13] = u[16];
    newU[14] = u[19];
    newU[15] = u[22];
    newU[16] = u[2];
    newU[17] = u[5];
    newU[18] = u[8];
    newU[19] = u[11];
    newU[20] = u[14];
    newU[21] = u[17];
    newU[22] = u[20];
    newU[23] = u[23];
}


__host__ __device__ void firstVector_kappa( const double* atu, double* finalVector, double kappa)
{
    finalVector[0] += 0.;
    finalVector[1] += 0.;
    finalVector[2] += 0.;
    finalVector[3] += kappa * (atu[3] + atu[10] + atu[17]);
    finalVector[4] += 0.;
    finalVector[5] += kappa * ( atu[5] + atu[12] ) /3.;
    finalVector[6] += kappa * ( atu[6] + atu[20] ) /3.;
    finalVector[7] += kappa * atu[7] / 9.;

    finalVector[8] += 0.;
    finalVector[9] += 0.;
    finalVector[10] += kappa * ( atu[10] + atu[3] + atu[17]);
    finalVector[11] += 0.;
    finalVector[12] += kappa * ( atu[12] + atu[5] ) / 3.;
    finalVector[13] += 0.;
    finalVector[14] += kappa * ( atu[14] + atu[21] ) /3.;
    finalVector[15] += kappa * atu[15] / 9.;

    finalVector[16] += 0.;
    finalVector[17] += kappa * ( atu[17] + atu[3] + atu[10] );
    finalVector[18] += 0.;
    finalVector[19] += 0.;
    finalVector[20] += kappa * ( atu[20] + atu[6] ) / 3.;
    finalVector[21] += kappa * ( atu[21] + atu[14] ) / 3.;
    finalVector[22] += 0.;
    finalVector[23] += kappa * atu[23] / 9.;
}


__host__ __device__ void firstVector_mu( const double* atu, double* finalVector, double b )
{
    finalVector[0] += 0;
    finalVector[1] += b * (atu[19] + atu[1]);
    finalVector[2] += b * (atu[11] + atu[2]);
    finalVector[3] += b * ( 4. * atu[3] - 2. * (atu[10] + atu[17]) ) / 3.;
    finalVector[4] += b * (atu[13] + atu[22] + 2. * atu[4]) / 3.;
    finalVector[5] += b * ( 7. * atu[5] - 2. * atu[12] ) / 9.;
    finalVector[6] += b * ( 7. * atu[6] - 2. * atu[20] ) / 9.;
    finalVector[7] += ( 10. * b * atu[7] ) / 27.;

    finalVector[8]  += 0;
    finalVector[9]  += b * (atu[18] + atu[9]);
    finalVector[10] += b * ( 4. * atu[10] - 2. * (atu[3] + atu[17]) ) / 3.;
    finalVector[11] += b * (atu[11] + atu[2]);
    finalVector[12] += b * ( 7. * atu[12] - 2. * atu[5] ) / 9.;
    finalVector[13] += b * (atu[4] + atu[22] + 2. * atu[13]) / 3.;
    finalVector[14] += b * ( 7. * atu[14] - 2. * atu[21] ) / 9.;
    finalVector[15] += (10. * b * atu[15] ) / 27.;

    finalVector[16] += 0;
    finalVector[17] += b * ( 4. * atu[17] - 2. * (atu[3] + atu[10]) ) / 3.;
    finalVector[18] += b * (atu[18] + atu[9]);
    finalVector[19] += b * (atu[19] + atu[1]);
    finalVector[20] += b * ( 7. * atu[20] - 2. * atu[6] ) / 9.;
    finalVector[21] += b * ( 7. * atu[21] - 2. * atu[14] ) / 9.;
    finalVector[22] += b * ( atu[4] + atu[13] + 2. * atu[22]) / 3.;
    finalVector[23] += (10. * b * atu[23] ) / 27.;
}
