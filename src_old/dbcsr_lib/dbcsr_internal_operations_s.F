!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2011  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief Processes MM stack and issues BLAS xGEMM calls
!>
!> \param[in] params           Stack of MM parameters
!> \param[in] stack_size       Number of parameters
!> \param[in] a_data           Left-matrix data
!> \param[in] b_data           Right-matrix data
!> \param[in,out] c_data       Product data
!> \param[in,out] error        error
! *****************************************************************************
  SUBROUTINE blas_process_mm_stack_s(params,&
       stack_size,&
       a_data, b_data, c_data, error)
    INTEGER, INTENT(IN)                       :: stack_size
    INTEGER, DIMENSION(n_mult_params,1:stack_size), &
      INTENT(IN)                              :: params
    REAL(kind=real_4), DIMENSION(*), INTENT(IN)         :: a_data, &
                                                 b_data
    REAL(kind=real_4), DIMENSION(*), INTENT(INOUT)      :: c_data
    TYPE(dbcsr_error_type), INTENT(inout)     :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'blas_process_mm_stack_s', &
      routineP = moduleN//':'//routineN

    INTEGER                                   :: sp

!   ---------------------------------------------------------------------------

    DO sp = 1, stack_size
       CALL SGEMM('N',&
            'N',&
            params(p_m,sp), params(p_n,sp),& !m, n
            params(p_k,sp),& ! k
            1.0_real_4,& ! alpha
            a_data(params(p_a_first,sp)),& ! A
            params(p_m,sp),& !lda
            b_data(params(p_b_first,sp)),& ! B
            params(p_k,sp),& !ldb
            1.0_real_4,& ! beta
            c_data(params(p_c_first,sp)), params(p_m,sp))
    ENDDO
  END SUBROUTINE blas_process_mm_stack_s

! *****************************************************************************
!> \brief Processes MM stack and issues internal MM calls.
!>
!> \param[in] params           Stack of MM parameters
!> \param[in] stack_size       Number of parameters
!> \param[in] a_data           Left-matrix data
!> \param[in] b_data           Right-matrix data
!> \param[in,out] c_data       Product data
!> \param[in,out] error        error
! *****************************************************************************
  SUBROUTINE internal_process_mm_stack_s(params, stack_size,&
       a_data, b_data, c_data, error)
    INTEGER, INTENT(IN)                       :: stack_size
    INTEGER, DIMENSION(n_mult_params,1:stack_size), &
      INTENT(IN)                              :: params
    REAL(kind=real_4), DIMENSION(*), INTENT(IN)         :: a_data, &
                                                 b_data
    REAL(kind=real_4), DIMENSION(*), INTENT(INOUT)      :: c_data
    TYPE(dbcsr_error_type), INTENT(inout)     :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'internal_process_mm_stack_s', &
      routineP = moduleN//':'//routineN

    INTEGER                                   :: sp

!   ---------------------------------------------------------------------------

    DO sp = 1, stack_size
       CALL internal_mm_s_nn(&
            params(p_m,sp),&
            params(p_n,sp),&
            params(p_k,sp),&
            a_data(params(p_a_first,sp)),&
            b_data(params(p_b_first,sp)),&
            c_data(params(p_c_first,sp)))
    ENDDO
  END SUBROUTINE internal_process_mm_stack_s


! *****************************************************************************
!> \brief Processes MM stack and issues SMM library calls
!>
!> \param[in] params           Stack of MM parameters
!> \param[in] stack_size       Number of parameters
!> \param[in] a_data           Left-matrix data
!> \param[in] b_data           Right-matrix data
!> \param[in,out] c_data       Product data
!> \param[in,out] error        error
! *****************************************************************************
  SUBROUTINE smm_process_mm_stack_s(params,&
       stack_size,&
       a_data, b_data, c_data, error)
    INTEGER, INTENT(IN)                       :: stack_size
    INTEGER, DIMENSION(n_mult_params,1:stack_size), &
      INTENT(IN)                              :: params
    REAL(kind=real_4), DIMENSION(*), INTENT(IN)         :: a_data, &
                                                 b_data
    REAL(kind=real_4), DIMENSION(*), INTENT(INOUT)      :: c_data
    TYPE(dbcsr_error_type), INTENT(inout)     :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'smm_process_mm_stack_s', &
      routineP = moduleN//':'//routineN

    INTEGER                                   :: sp

!   ---------------------------------------------------------------------------

    DO sp = 1, stack_size
       CALL smm_snn(&
            params(p_m,sp),&
            params(p_n,sp),&
            params(p_k,sp),&
            a_data(params(p_a_first,sp)),&
            b_data(params(p_b_first,sp)),&
            c_data(params(p_c_first,sp)))
    ENDDO
  END SUBROUTINE smm_process_mm_stack_s


! *****************************************************************************
!> \brief Processes MM stack and issues Plasma xGEMM calls.
!>
!> \param[in] params           Stack of MM parameters
!> \param[in] stack_size       Number of parameters
!> \param[in] a_data           Left-matrix data
!> \param[in] b_data           Right-matrix data
!> \param[in,out] c_data       Product data
!> \param[in,out] error        error
! *****************************************************************************
  SUBROUTINE plasma_process_mm_stack_s(params, stack_size,&
       a_data, b_data, c_data, error)
    INTEGER, INTENT(IN)                       :: stack_size
    INTEGER, DIMENSION(n_mult_params,1:stack_size), &
      INTENT(IN)                              :: params
    REAL(kind=real_4), DIMENSION(*), INTENT(IN)         :: a_data, &
                                                 b_data
    REAL(kind=real_4), DIMENSION(*), INTENT(INOUT)      :: c_data
    TYPE(dbcsr_error_type), INTENT(inout)     :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'plasma_process_mm_stack_s', &
      routineP = moduleN//':'//routineN

    INTEGER                                   :: sp

!   ---------------------------------------------------------------------------
#ifdef __PLASMA
    INCLUDE 'plasmaf.h'
#else
    CALL dbcsr_assert(.FALSE.,&
         dbcsr_fatal_level, dbcsr_internal_error, routineN,&
         "PLASMA support not compiled.", __LINE__, error=error)
#endif
    !
    DO sp = 1, stack_size
#ifdef __PLASMA
       CALL plasma_SGEMM(&
            'N',&
            'N',&
            params(p_m,sp), params(p_n,sp),& !m, n
            params(p_k,sp),& ! k
            1.0_real_4,& ! alpha
            a_data(params(p_a_first,sp)),& ! A
            params(p_m,sp),& !lda
            b_data(params(p_b_first,sp)),& ! B
            params(p_k,sp),& !ldb
            1.0_real_4,& ! beta
            c_data(params(p_c_first,sp)), params(p_m,sp),& !c, ldc
            plasma_info)
       CALL dbcsr_assert( plasma_info, "EQ", 0, dbcsr_fatal_level, dbcsr_internal_error, routineN,&
            "plasma_gemm failed", __LINE__, error=error)
#else
       CALL dbcsr_assert( .FALSE., dbcsr_fatal_level, dbcsr_internal_error, routineN,&
            "plasma badly set", __LINE__, error=error)
#endif
    ENDDO
  END SUBROUTINE plasma_process_mm_stack_s



  PURE SUBROUTINE internal_mm_s_nn(&
       M,N,K,A,B,C)
    INTEGER, INTENT(IN)                      :: M, N, K
    REAL(kind=real_4), INTENT(INOUT)                   :: C(M,N)
    REAL(kind=real_4), INTENT(IN)                      :: B(K,N)
    REAL(kind=real_4), INTENT(IN)                      :: A(M,K)
    C(:,:) = C(:,:) + MATMUL (A, B)
  END SUBROUTINE internal_mm_s_nn



!> \brief Calculates norms of the entire matrix with minimal overhead.
  SUBROUTINE calc_norms_s(norms, nrows,&
       row_p, col_i, blk_p, rbs, cbs, DATA, local, local2global)
    REAL(kind=sp), DIMENSION(:), INTENT(OUT) :: norms
    INTEGER, INTENT(IN)                      :: nrows
    INTEGER, DIMENSION(1:nrows+1), &
      INTENT(IN)                             :: row_p
    INTEGER, DIMENSION(*), INTENT(IN)        :: col_i, blk_p, rbs, cbs
    REAL(kind=real_4), DIMENSION(*), &
      INTENT(IN)                             :: DATA
    LOGICAL, INTENT(IN)                      :: local
    INTEGER, DIMENSION(*), INTENT(IN)        :: local2global

    INTEGER                                  :: blk, bp, bpe, row, row_i, &
                                                row_size

!   ---------------------------------------------------------------------------

    !$omp parallel default(none) &
    !$omp          private (row_i, row, row_size, blk, bp, bpe) &
    !$omp          shared (nrows, local) &
    !$omp          shared (local2global, rbs, cbs, row_p, col_i, blk_p, &
    !$omp                  data, norms)
    !$omp do
    DO row_i = 1, nrows
       IF (local) THEN
          row = local2global(row_i)
       ELSE
          row = row_i
       ENDIF
       row_size = rbs(row)
       DO blk = row_p(row_i)+1, row_p(row_i+1)
          IF (blk_p(blk) .NE. 0) THEN
             bp = ABS(blk_p(blk))
             bpe = bp + row_size * cbs(col_i(blk)) - 1
             norms(blk) = SQRT (REAL (SUM(ABS(DATA(bp:bpe))**2), KIND=sp))
          ELSE
             norms(blk) = 0.0_sp
          ENDIF
       ENDDO
    ENDDO
    !$omp end do
    !$omp end parallel
  END SUBROUTINE calc_norms_s

!> \brief Calculates norms of the entire matrix with minimal overhead.
  SUBROUTINE calc_norms_list_s(norms, nblks,&
       blki, rbs, cbs, DATA, local, local2global_rows, local2global_cols)
    REAL(kind=sp), DIMENSION(:), INTENT(OUT) :: norms
    INTEGER, INTENT(IN)                      :: nblks
    INTEGER, DIMENSION(3,nblks), INTENT(IN)  :: blki
    INTEGER, DIMENSION(:), INTENT(IN)        :: rbs, cbs
    REAL(kind=real_4), DIMENSION(:), &
      INTENT(IN)                             :: DATA
    LOGICAL, INTENT(IN)                      :: local
    INTEGER, DIMENSION(:), INTENT(IN)        :: local2global_rows
    INTEGER, DIMENSION(:), INTENT(IN)        :: local2global_cols

    INTEGER                                  :: blk, bp, bpe, row, col, &
                                                row_size

!   ---------------------------------------------------------------------------

    !$omp parallel default(none) &
    !$omp          private (row, col, blk, bp, bpe) &
    !$omp          shared (local, nblks) &
    !$omp          shared (rbs, cbs, blki, &
    !$omp                  data, norms, local2global_rows, local2global_cols)
    !$omp do
    DO blk = 1, nblks
       IF (blki(3,blk) .NE. 0) THEN
          bp = blki(3,blk)
          IF (local) THEN
             row = local2global_rows(blki(1,blk))
             col = local2global_cols(blki(2,blk))
          ELSE
             row = blki(1,blk)
             col = blki(2,blk)
          ENDIF
          bpe = bp + rbs(row) * cbs(col) - 1
          norms(blk) = SQRT (REAL (SUM(ABS(DATA(bp:bpe))**2), KIND=sp))
       ELSE
          norms(blk) = 0.0_sp
       ENDIF
    ENDDO
    !$omp end do
    !$omp end parallel
  END SUBROUTINE calc_norms_list_s


