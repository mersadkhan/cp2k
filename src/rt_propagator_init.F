!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2011  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief Routines for the prepares teh matrices for the propagators
!> \author Florian Schiffmann (02.09)
! *****************************************************************************
MODULE rt_propagator_init

  USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm
  USE cp_dbcsr_types,                  ONLY: cp_dbcsr_p_type
  USE cp_fm_basic_linalg,              ONLY: cp_fm_gemm,&
                                             cp_fm_scale,&
                                             cp_fm_upper_to_full
  USE cp_fm_diag,                      ONLY: cp_fm_syevd
  USE cp_fm_types,                     ONLY: cp_fm_create,&
                                             cp_fm_p_type,&
                                             cp_fm_release,&
                                             cp_fm_to_fm,&
                                             cp_fm_type
  USE input_constants,                 ONLY: do_arnoldi,&
                                             do_cn,&
                                             do_diag,&
                                             do_em,&
                                             do_etrs,&
                                             do_pade,&
                                             do_taylor
  USE kinds,                           ONLY: dp
  USE qs_environment_types,            ONLY: get_qs_env,&
                                             qs_environment_type
  USE qs_ks_methods,                   ONLY: qs_ks_update_qs_env
  USE qs_ks_types,                     ONLY: qs_ks_env_type
  USE qs_mo_types,                     ONLY: mo_set_p_type
  USE rt_make_propagators,             ONLY: make_etrs_exp
  USE rt_matrix_exp,                   ONLY: get_nsquare_norder
  USE rt_propagation_methods,          ONLY: calc_SinvH,&
                                             calc_update_rho,&
                                             put_data_to_history,&
                                             s_matrices_create
  USE rt_propagation_types,            ONLY: get_rtp,&
                                             rt_prop_type
  USE rt_propagation_utils,            ONLY: calc_S_derivs
#include "cp_common_uses.h"

  IMPLICIT NONE


  CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_propagator_init'

  PUBLIC :: init_propagators,&
            init_emd_propagators


CONTAINS


! *****************************************************************************
!> \brief prepares the initial matrices for the propagators
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE init_propagators(qs_env,error)

    TYPE(qs_environment_type), POINTER       :: qs_env
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'init_propagators', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: i
    LOGICAL                                  :: diagonalize
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: s_mat
    TYPE(cp_fm_p_type), DIMENSION(:), &
      POINTER                                :: exp_H_new, exp_H_old, mos_old
    TYPE(mo_set_p_type), DIMENSION(:), &
      POINTER                                :: mos
    TYPE(rt_prop_type), POINTER              :: rtp

    CALL get_qs_env(qs_env,&
         mos=mos,&
         rtp=rtp,&
         matrix_s=s_mat,&
         error=error)

    CALL get_rtp (rtp=rtp,exp_H_old=exp_H_old,exp_H_new=exp_H_new,mos_old=mos_old,error=error)



    SELECT CASE(qs_env%dft_control%rtp_control%mat_exp)
    CASE(do_taylor,do_pade,do_diag)
       CALL get_maxabs_eigval(rtp,qs_env,error)
       SELECT CASE(qs_env%dft_control%rtp_control%propagator)
       CASE (do_cn,do_em)
          diagonalize=(qs_env%dft_control%rtp_control%mat_exp==do_diag)
          IF(qs_env%dft_control%rtp_control%propagator==do_cn)diagonalize=.FALSE.
          CALL s_matrices_create (s_mat,rtp,diagonalize,error)
          CALL calc_SinvH(exp_H_old,qs_env,error)
          DO i=1,SIZE(exp_H_old)
             CALL cp_fm_to_fm(exp_H_old(i)%matrix,rtp%exp_H_new(i)%matrix,error)
          END DO

       CASE (do_etrs)

          diagonalize=(qs_env%dft_control%rtp_control%mat_exp==do_diag)
          CALL s_matrices_create (s_mat,rtp,diagonalize,error)

          CALL make_etrs_exp(exp_H_old,qs_env,error)
          DO i=1,SIZE(exp_H_old)
             CALL cp_fm_to_fm(exp_H_old(i)%matrix,rtp%exp_H_new(i)%matrix,error)
          END DO
       END SELECT
    CASE(do_arnoldi)
       diagonalize=.FALSE.
       CALL s_matrices_create (s_mat,rtp,diagonalize,error)
       CALL calc_SinvH(exp_H_old,qs_env,error)
       DO i=1,SIZE(exp_H_old)
          CALL cp_fm_to_fm(exp_H_old(i)%matrix,rtp%exp_H_new(i)%matrix,error)
       END DO
    END SELECT

    IF(rtp%history%mos_or_H==2)&
         CALL put_data_to_history(qs_env,exp_H=exp_H_old,ihist=1,error=error)
    IF(rtp%history%mos_or_H==1)&
         CALL put_data_to_history(qs_env,mos=mos_old,s_mat=s_mat,ihist=1,error=error)

  END SUBROUTINE init_propagators

! *****************************************************************************
!> \brief gets an estimate for the 2-norm of KS (diagnaliztion of KS) and
!>        calculates the order and number of squaring steps for Taylor or
!>        Pade matrix exponential
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE get_maxabs_eigval(rtp,qs_env,error)
    TYPE(rt_prop_type), POINTER              :: rtp
    TYPE(qs_environment_type), POINTER       :: qs_env
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'get_maxabs_eigval', &
      routineP = moduleN//':'//routineN
    REAL(KIND=dp), PARAMETER                 :: one = 1.0_dp , zero = 0.0_dp

    INTEGER                                  :: ispin, method, ndim, stat
    LOGICAL                                  :: emd, failure, is_present
    REAL(dp)                                 :: max_eval, min_eval, norm2, &
                                                scale, t
    REAL(dp), ALLOCATABLE, DIMENSION(:)      :: eigval_H
    TYPE(cp_dbcsr_p_type), DIMENSION(:), &
      POINTER                                :: matrix_ks, s_mat
    TYPE(cp_fm_type), POINTER                :: H_fm, tmp_mat_H

    failure=.FALSE.

    is_present=(ASSOCIATED(rtp%S_half))
    IF(.NOT.is_present)THEN
       CALL cp_fm_create(rtp%S_half,&
            matrix_struct=rtp%S_inv%matrix_struct,&
            name="S_half",&
            error=error)
       CALL cp_fm_create(rtp%S_minus_half,&
            matrix_struct=rtp%S_inv%matrix_struct,&
            name="S_minus_half",&
            error=error)
    END IF

    t=rtp%dt
    CALL get_qs_env(qs_env=qs_env,matrix_ks=matrix_ks,matrix_s=s_mat,error=error)
    CALL  s_matrices_create (s_mat,rtp,.TRUE.,error)

    CALL cp_fm_create(H_fm,&
         matrix_struct=rtp%S_inv%matrix_struct,&
         name="RTP_H_FM",&
         error=error)

    CALL cp_fm_create(tmp_mat_H,&
         matrix_struct=rtp%S_inv%matrix_struct,&
         name="TMP_H",&
         error=error)

    ndim=H_fm%matrix_struct%nrow_global
    scale=1.0_dp
    IF(qs_env%dft_control%rtp_control%propagator==do_etrs)scale=2.0_dp
    t=-t/scale
    ALLOCATE(eigval_H(ndim),stat=stat)
    CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)

    IF(qs_env%dft_control%rtp_control%mat_exp==do_taylor)method=1
    IF(qs_env%dft_control%rtp_control%mat_exp==do_pade)method=2
    emd=(.NOT.qs_env%dft_control%rtp_control%fixed_ions)


    DO ispin=1,SIZE(matrix_ks)

       CALL copy_dbcsr_to_fm(matrix_ks(ispin)%matrix,H_fm,error=error)
       CALL cp_fm_upper_to_full(H_fm,tmp_mat_H,error)
       CALL cp_fm_scale(t,H_fm,error)
       ndim=H_fm%matrix_struct%nrow_global


       CALL cp_fm_gemm("N","N",ndim,ndim,ndim,one,H_fm,rtp%S_minus_half,zero,&
            tmp_mat_H,error)
       CALL cp_fm_gemm("N","N",ndim,ndim,ndim,one,rtp%S_minus_half,tmp_mat_H,zero,&
            H_fm,error)

       CALL cp_fm_syevd(H_fm,tmp_mat_H,eigval_H,error)
       min_eval=MINVAL(eigval_H)
       max_eval=MAXVAL(eigval_H)
       norm2=2.0_dp*MAX(ABS(min_eval),ABS(max_eval))
       CALL get_nsquare_norder(norm2,rtp%orders(1,ispin),rtp%orders(2,ispin),&
            qs_env%dft_control%rtp_control%eps_exp,method ,emd,error)
    END DO

    DEALLOCATE(eigval_H,stat=stat)
    CPPostcondition(stat==0,cp_failure_level,routineP,error,failure)
    IF(.NOT.is_present)THEN
       CALL cp_fm_release(rtp%S_half,error)
       CALL cp_fm_release(rtp%S_minus_half,error)
    END IF

    CALL cp_fm_release(H_fm,error)
    CALL cp_fm_release(tmp_mat_H,error)

  END SUBROUTINE get_maxabs_eigval

! *****************************************************************************
!> \brief computs all matrices needed to initialize emd (S_derivs, SinvH,
!>        SinvB and forces)
!> \author Florian Schiffmann (02.09)
! *****************************************************************************

  SUBROUTINE init_emd_propagators(qs_env,error)
    TYPE(qs_environment_type), POINTER       :: qs_env
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'init_emd_propagators', &
      routineP = moduleN//':'//routineN

    TYPE(qs_ks_env_type), POINTER            :: ks_env

!density matrix

       CALL calc_update_rho(qs_env,error)
       CALL get_qs_env(qs_env=qs_env,ks_env=ks_env,error=error)
       !derivatives of the potential
       CALL qs_ks_update_qs_env(ks_env,qs_env=qs_env,calculate_forces=.TRUE.,&
            error=error)
       !derivativs of the overlap needed for EMD
       CALL calc_S_derivs(qs_env,error)
       ! a bit hidden, but computs SinvH and SinvB (calc_SinvH for CN,EM and ARNOLDI)
       ! make_etrs_exp in case of ETRS in combination with TAYLOR and PADE 
       CALL init_propagators(qs_env,error)

   END SUBROUTINE init_emd_propagators

END MODULE rt_propagator_init
