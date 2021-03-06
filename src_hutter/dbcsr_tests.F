!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2011  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief   Tests for CP2K DBCSR operations
!> \author  Urban Borstnik
!> \date    2010-02-08
!> \version 1.0
!>
!> <b>Modification history:</b>
!> - Created 2010-02-08
! *****************************************************************************
MODULE dbcsr_tests
  USE array_types,                     ONLY: array_data,&
                                             array_i1d_obj,&
                                             array_release,&
                                             array_size
  USE dbcsr_block_access
  USE dbcsr_data_methods
  USE dbcsr_dist_operations,           ONLY: dbcsr_dist_bin,&
                                             dbcsr_mp_make_env
  USE dbcsr_error_handling,            ONLY: dbcsr_assert,&
                                             dbcsr_error_set,&
                                             dbcsr_error_stop,&
                                             dbcsr_error_type,&
                                             dbcsr_fatal_level,&
                                             dbcsr_wrong_args_error
  USE dbcsr_message_passing,           ONLY: dmp_max,&
                                             mp_cart_create,&
                                             mp_dims_create,&
                                             mp_environ,&
                                             mp_sum,&
                                             mp_sync
  USE dbcsr_methods
  USE dbcsr_operations
  USE dbcsr_ptr_util
  USE dbcsr_test_methods
  USE dbcsr_transformations
  USE dbcsr_types
  USE dbcsr_util
  USE dbcsr_work_operations
  USE kinds,                           ONLY: dp,&
                                             int_8,&
                                             real_8
  USE machine,                         ONLY: m_walltime

  !$ USE OMP_LIB
#include "cp_common_uses.h"

  IMPLICIT NONE

  PRIVATE

  PUBLIC :: cp_test_multiplies

  CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_tests'

CONTAINS

! *****************************************************************************
!> \brief Performs a variety of matrix multiplies of same matrices on different
!>        processor grids
!> \param[in] mp_group          MPI communicator
!> \param[in] io_unit           which unit to write to, if not negative
!> \param[in] nproc             number of processors to test on
!> \param[in] matrix_sizes      size of matrices to test
!> \param[in] matrix_types      types of matrices to create
!> \param[in] trs               transposes of the two matrices
!> \param[in] bs_m, bs_n, bs_k  block sizes of the 3 dimensions
!> \param[in] sparsities        sparsities of matrices to create
!> \param[in] alpha, beta       alpha and beta values to use in multiply
!> \param[in] data_type         matrix data type
!> \param[in] n_loops           number of repetition for each multiplication
!> \param[in] eps               eps value for filtering
!> \param[in] deteriminstic     attempt deterministic behavior
!> \param[in,out] error         cp2k error
! *****************************************************************************
  SUBROUTINE cp_test_multiplies (mp_group, io_unit, nproc,&
       matrix_sizes, matrix_types, trs, &
       bs_m, bs_n, bs_k, sparsities, alpha, beta, data_type, &
       n_loops, eps, deterministic,&
       error)
    INTEGER, INTENT(IN)                      :: mp_group, io_unit
    INTEGER, DIMENSION(:), POINTER           :: nproc
    INTEGER, DIMENSION(:), INTENT(in)        :: matrix_sizes
    CHARACTER, DIMENSION(3), INTENT(in)      :: matrix_types
    LOGICAL, DIMENSION(2), INTENT(in)        :: trs
    INTEGER, DIMENSION(:), POINTER           :: bs_m, bs_n, bs_k
    REAL(kind=dp), DIMENSION(3), INTENT(in)  :: sparsities
    REAL(kind=dp), INTENT(in)                :: alpha, beta
    INTEGER, INTENT(IN)                      :: data_type, n_loops
    REAL(kind=dp), INTENT(in)                :: eps
    LOGICAL, INTENT(in)                      :: deterministic
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: &
      fmt_desc = '(A,3(1X,I6),1X,A,2(1X,I5),1X,A,2(1X,L1))', &
      routineN = 'cp_test_multiplies', routineP = moduleN//':'//routineN

    CHARACTER                                :: t_a, t_b
    INTEGER                                  :: bmax, bmin, error_handle, &
                                                mynode, numnodes
    INTEGER, ALLOCATABLE, DIMENSION(:, :)    :: group_sizes
    INTEGER, DIMENSION(2)                    :: npdims
    LOGICAL                                  :: pgiven
    TYPE(array_i1d_obj) :: col_dist_a, col_dist_b, col_dist_c, row_dist_a, &
      row_dist_b, row_dist_c, sizes_k, sizes_m, sizes_n
    TYPE(dbcsr_distribution_obj)             :: dist_a, dist_b, dist_c
    TYPE(dbcsr_error_type)                   :: dbcsr_error
    TYPE(dbcsr_mp_obj)                       :: mp_env
    TYPE(dbcsr_obj)                          :: matrix_a, matrix_b, matrix_c

!   ---------------------------------------------------------------------------

    CALL dbcsr_error_set (routineN, error_handle, error=dbcsr_error)
    ! Create the row/column block sizes.
    IF (ASSOCIATED (bs_m)) THEN
       bmin = MINVAL (bs_m(2::2))
       bmax = MAXVAL (bs_m(2::2))
       CALL dbcsr_make_random_block_sizes (sizes_m, matrix_sizes(1), bs_m)
    ELSE
       CALL dbcsr_make_random_block_sizes (sizes_m, matrix_sizes(1), (/ 1, 13, 2, 5 /))
       bmin = 5 ; bmax = 13
    ENDIF
    IF (ASSOCIATED (bs_n)) THEN
       bmin = MIN (bmin, MINVAL (bs_n(2::2)))
       bmax = MAX (bmax, MAXVAL (bs_n(2::2)))
       CALL dbcsr_make_random_block_sizes (sizes_n, matrix_sizes(2), bs_n)
    ELSE
       CALL dbcsr_make_random_block_sizes (sizes_n, matrix_sizes(2), (/ 1, 13, 2, 5 /))
       bmin = MIN (bmin, 5) ; bmax = MAX (bmax, 13)
    ENDIF
    IF (ASSOCIATED (bs_k)) THEN
       bmin = MIN (bmin, MINVAL (bs_k(2::2)))
       bmax = MAX (bmax, MAXVAL (bs_k(2::2)))
       CALL dbcsr_make_random_block_sizes (sizes_k, matrix_sizes(3), bs_k)
    ELSE
       CALL dbcsr_make_random_block_sizes (sizes_k, matrix_sizes(3), (/ 1, 13, 2, 5 /))
       bmin = MIN (bmin, 5) ; bmax = MAX (bmax, 13)
    ENDIF
    !
    ! Create dist

    ! Create the random matrices.
    CALL dbcsr_mp_make_env (mp_env, mp_group, error=dbcsr_error)
    npdims(1) = dbcsr_mp_nprows (mp_env)
    npdims(2) = dbcsr_mp_npcols (mp_env)
    CALL dbcsr_dist_bin (row_dist_c, array_size(sizes_m), npdims(1),&
         array_data(sizes_m), error=dbcsr_error)
    CALL dbcsr_dist_bin (col_dist_c, array_size(sizes_n), npdims(2),&
         array_data(sizes_n), error=dbcsr_error)
    CALL dbcsr_distribution_new (dist_c, mp_env, row_dist_c, col_dist_c)
    CALL dbcsr_make_random_matrix (matrix_c, sizes_m, sizes_n, "Matrix C",&
         REAL(sparsities(3), real_8),&
         mp_group, data_type=data_type, dist=dist_c, nondet=.not.deterministic,&
         error=dbcsr_error)
    CALL dbcsr_distribution_release (dist_c)
    IF (trs(1)) THEN
       CALL dbcsr_dist_bin (row_dist_a, array_size(sizes_k), npdims(1),&
            array_data(sizes_k), error=dbcsr_error)
       CALL dbcsr_dist_bin (col_dist_a, array_size(sizes_m), npdims(2),&
            array_data(sizes_m), error=dbcsr_error)
       CALL dbcsr_distribution_new (dist_a, mp_env, row_dist_a, col_dist_a)
       CALL dbcsr_make_random_matrix (matrix_a, sizes_k, sizes_m, "Matrix A",&
            REAL(sparsities(1), real_8),&
            mp_group, data_type=data_type, dist=dist_a, nondet=.not.deterministic,&
            error=dbcsr_error)
       CALL array_release (row_dist_a)
       CALL array_release (col_dist_a)
    ELSE
       CALL dbcsr_dist_bin (col_dist_a, array_size(sizes_k), npdims(2),&
            array_data(sizes_k), error=dbcsr_error)
       CALL dbcsr_distribution_new (dist_a, mp_env, row_dist_c, col_dist_a)
       CALL dbcsr_make_random_matrix (matrix_a, sizes_m, sizes_k, "Matrix A",&
            REAL(sparsities(1), real_8),&
            mp_group, data_type=data_type, dist=dist_a, nondet=.not.deterministic,&
            error=dbcsr_error)
       CALL array_release (col_dist_a)
    ENDIF
    CALL dbcsr_distribution_release (dist_a)
    IF (trs(2)) THEN
       CALL dbcsr_dist_bin (row_dist_b, array_size(sizes_n), npdims(1),&
            array_data(sizes_n), error=dbcsr_error)
       CALL dbcsr_dist_bin (col_dist_b, array_size(sizes_k), npdims(2),&
            array_data(sizes_k), error=dbcsr_error)
       CALL dbcsr_distribution_new (dist_b, mp_env, row_dist_b, col_dist_b)
       CALL dbcsr_make_random_matrix (matrix_b, sizes_n, sizes_k, "Matrix B",&
            REAL(sparsities(2), real_8),&
            mp_group, data_type=data_type, dist=dist_b, nondet=.not.deterministic,&
            error=dbcsr_error)
       CALL array_release (row_dist_b)
       CALL array_release (col_dist_b)
    ELSE
       CALL dbcsr_dist_bin (row_dist_b, array_size(sizes_k), npdims(1),&
            array_data(sizes_k), error=dbcsr_error)
       CALL dbcsr_distribution_new (dist_b, mp_env, row_dist_b, col_dist_c)
       CALL dbcsr_make_random_matrix (matrix_b, sizes_k, sizes_n, "Matrix B",&
            REAL(sparsities(2), real_8),&
            mp_group, data_type=data_type, dist=dist_b, nondet=.not.deterministic,&
            error=dbcsr_error)
       CALL array_release (row_dist_b)
    ENDIF
    CALL dbcsr_mp_release (mp_env)
    CALL dbcsr_distribution_release (dist_b)
    CALL array_release (row_dist_c)
    CALL array_release (col_dist_c)
    CALL array_release (sizes_m)
    CALL array_release (sizes_n)
    CALL array_release (sizes_k)
    ! Prepare test parameters
    IF (io_unit .GT. 0) THEN
       WRITE(io_unit, fmt_desc)"Multiplication with sizes",matrix_sizes(1:3),&
            "min/max block sizes", bmin, bmax, "transposed?", trs(1:2)
    ENDIF
    CALL mp_environ (numnodes, mynode, mp_group)
    pgiven = ASSOCIATED (nproc)
    IF (pgiven) pgiven = nproc(1) .NE. 0
    IF (pgiven) THEN
       ALLOCATE (group_sizes (SIZE (nproc), 2))
       group_sizes(:,1) = nproc(:)
       group_sizes(:,2) = 0
    ELSE
       !ALLOCATE (group_sizes (numnodes, 2))
       !DO test = numnodes, 1, -1
       !   group_sizes(1+numnodes-test, 1:2) = (/ test, 0 /)
       !ENDDO
       ALLOCATE (group_sizes (1, 2))
       group_sizes(1, 1:2) = (/ numnodes, 0 /)
    ENDIF
    t_a = 'N' ; IF (trs(1)) t_a = 'T'
    t_b = 'N' ; IF (trs(2)) t_b = 'T'
    CALL test_multiplies_multiproc (mp_group, group_sizes,&
         matrix_a, matrix_b, matrix_c, t_a, t_b,&
         dbcsr_scalar (REAL(alpha, real_8)), dbcsr_scalar (REAL(beta, real_8)),&
         n_loops=n_loops, eps=eps,&
         io_unit = io_unit, error=error)
    CALL dbcsr_release (matrix_a)
    CALL dbcsr_release (matrix_b)
    CALL dbcsr_release (matrix_c)
    CALL dbcsr_error_stop (error_handle, error=dbcsr_error)
  END SUBROUTINE cp_test_multiplies

! *****************************************************************************
!> \brief Performs a variety of matrix multiplies of same matrices on different
!>        processor grids
!> \param[in] mp_group          MPI communicator
!> \param[in] group_sizes       array of (sub) communicator
!>                              sizes to test (2-D)
!> \param[in] matrix_a, matrix_b, matrix_c    matrices to multiply
!> \param[in] io_unit           which unit to write to, if not negative
! *****************************************************************************
  SUBROUTINE test_multiplies_multiproc (mp_group, group_sizes,&
       matrix_a, matrix_b, matrix_c,&
       transa, transb, alpha, beta, limits, retain_sparsity,&
       n_loops, eps,&
       io_unit, error)
    INTEGER, INTENT(IN)                      :: mp_group
    INTEGER, DIMENSION(:, :)                 :: group_sizes
    TYPE(dbcsr_obj), INTENT(in)              :: matrix_a, matrix_b, matrix_c
    CHARACTER, INTENT(in)                    :: transa, transb
    TYPE(dbcsr_scalar_type), INTENT(in)      :: alpha, beta
    INTEGER, DIMENSION(6), INTENT(in), &
      OPTIONAL                               :: limits
    LOGICAL, INTENT(in), OPTIONAL            :: retain_sparsity
    INTEGER, INTENT(IN)                      :: n_loops
    REAL(kind=dp), INTENT(in)                :: eps
    INTEGER, INTENT(IN)                      :: io_unit
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'test_multiplies_multiproc', &
      routineP = moduleN//':'//routineN
    INTEGER                                  :: error_handle, group, &
                                                loop_iter, mynode, numnodes, &
                                                test
    INTEGER(kind=int_8)                      :: flop, flop_sum
    CHARACTER(len=*), PARAMETER :: fmt_per_run_total = &
      '(A,1X,I5,1X,A,1X,F9.3,1X,"s,",1X,EN12.3,1X,"FLOP/s",2(1X,E13.7))', &
      fmt_per_run_local = &
      '(A,1X,I5,1X,A,1X,F9.3,1X,"s,",1X,EN12.3,1X,"FLOP/s")'

    INTEGER, DIMENSION(2)                    :: myploc, npdims
    LOGICAL                                  :: i_am_alive
    REAL(kind=real_8)                        :: cs, cs_first, cs_pos, &
                                                cs_pos_first, flops_all, t1, &
                                                t2
    TYPE(array_i1d_obj)                      :: col_dist_a, col_dist_b, &
                                                col_dist_c, row_dist_a, &
                                                row_dist_b, row_dist_c
    TYPE(dbcsr_distribution_obj)             :: dist_a, dist_b, dist_c
    TYPE(dbcsr_error_type)                   :: dbcsr_error
    TYPE(dbcsr_mp_obj)                       :: mp_env
    TYPE(dbcsr_obj)                          :: m_a, m_b, m_c

!   ---------------------------------------------------------------------------

    CALL dbcsr_error_set (routineN, error_handle, error=dbcsr_error)
    CALL dbcsr_assert (SIZE(group_sizes, 2), "EQ", 2, dbcsr_fatal_level,&
         dbcsr_wrong_args_error, routineN,&
         "second dimension of group_sizes must be 2",__LINE__,dbcsr_error)
    CALL dbcsr_init (m_a)
    CALL dbcsr_init (m_b)
    CALL dbcsr_init (m_c)
    p_sizes: DO test = 1, SIZE(group_sizes, 1)
       t2 = 0.0_real_8
       flop_sum = 0
       loops: DO loop_iter = 1, n_loops
          npdims(1:2) = group_sizes(test, 1:2)
          numnodes = npdims(1) * npdims(2)
          group = dbcsr_mp_group (dbcsr_distribution_mp (&
                      dbcsr_distribution (matrix_c)))
          IF (numnodes .EQ. 0) THEN
             CALL dbcsr_mp_make_env (mp_env, group, nprocs=MAXVAL(npdims),&
                  error=dbcsr_error)
          ELSE
             CALL dbcsr_mp_make_env (mp_env, group, pgrid_dims=npdims,&
                  error=dbcsr_error)
          ENDIF
          CALL dbcsr_assert (numnodes, "GE", 0, dbcsr_fatal_level,&
               dbcsr_wrong_args_error, routineN,&
               "Cartesian sides must be greater or equal to 0",__LINE__,dbcsr_error)
          IF (.FALSE.) THEN
             ! Let MPI decide our process grid
             IF (numnodes .EQ. 0) THEN
                numnodes = MAXVAL (npdims)
                npdims(1:2) = 0
                CALL mp_dims_create (numnodes, npdims)
             ENDIF
             ! Create communicator with given cartesian grid
             CALL mp_cart_create (mp_group, 2, npdims, myploc, group)
          ENDIF
          i_am_alive = dbcsr_mp_active (mp_env)
          alive: IF (i_am_alive) THEN
             npdims(1) = dbcsr_mp_nprows (mp_env)
             npdims(2) = dbcsr_mp_npcols (mp_env)
             group = dbcsr_mp_group (mp_env)
             CALL mp_environ (numnodes, mynode, group)
             ! Row & column distributions
             CALL dbcsr_dist_bin (row_dist_a,&
                  dbcsr_nblkrows_total (matrix_a), npdims(1),&
                  array_data(dbcsr_row_block_sizes(matrix_a)), error=dbcsr_error)
             CALL dbcsr_dist_bin (col_dist_a,&
                  dbcsr_nblkcols_total (matrix_a), npdims(2),&
                  array_data(dbcsr_col_block_sizes(matrix_a)), error=dbcsr_error)
             CALL dbcsr_dist_bin (row_dist_b,&
                  dbcsr_nblkrows_total (matrix_b), npdims(1),&
                  array_data(dbcsr_row_block_sizes(matrix_b)), error=dbcsr_error)
             CALL dbcsr_dist_bin (col_dist_b,&
                  dbcsr_nblkcols_total (matrix_b), npdims(2),&
                  array_data(dbcsr_col_block_sizes(matrix_b)), error=dbcsr_error)
             CALL dbcsr_dist_bin (row_dist_c,&
                  dbcsr_nblkrows_total (matrix_c), npdims(1),&
                  array_data(dbcsr_row_block_sizes(matrix_c)), error=dbcsr_error)
             CALL dbcsr_dist_bin (col_dist_c,&
                  dbcsr_nblkcols_total (matrix_c), npdims(2),&
                  array_data(dbcsr_col_block_sizes(matrix_c)), error=dbcsr_error)
             CALL dbcsr_distribution_new (dist_a,&
                  mp_env, row_dist_a, col_dist_a)
             CALL dbcsr_distribution_new (dist_b,&
                  mp_env, row_dist_b, col_dist_b)
             CALL dbcsr_distribution_new (dist_c,&
                  mp_env, row_dist_c, col_dist_c)
             CALL array_release (row_dist_a)
             CALL array_release (col_dist_a)
             CALL array_release (row_dist_b)
             CALL array_release (col_dist_b)
             CALL array_release (row_dist_c)
             CALL array_release (col_dist_c)
             ! Redistribute the matrices
             ! A
             CALL dbcsr_create (m_a, "Test for "//TRIM(dbcsr_name (matrix_a)),&
                  dist_a, dbcsr_type_no_symmetry,&
                  dbcsr_row_block_sizes (matrix_a),&
                  dbcsr_col_block_sizes (matrix_a),&
                  data_type=dbcsr_get_data_type (matrix_a),&
                  error=dbcsr_error)
             CALL dbcsr_distribution_release (dist_a)
             CALL dbcsr_redistribute (matrix_a, m_a, error=dbcsr_error)
             ! B
             CALL dbcsr_create (m_b, "Test for "//TRIM(dbcsr_name (matrix_b)),&
                  dist_b, dbcsr_type_no_symmetry,&
                  dbcsr_row_block_sizes (matrix_b),&
                  dbcsr_col_block_sizes (matrix_b),&
                  data_type=dbcsr_get_data_type (matrix_b),&
                  error=dbcsr_error)
             CALL dbcsr_distribution_release (dist_b)
             CALL dbcsr_redistribute (matrix_b, m_b, error=dbcsr_error)
             ! C
             CALL dbcsr_create (m_c, "Test for "//TRIM(dbcsr_name (matrix_c)),&
                  dist_c, dbcsr_type_no_symmetry,&
                  dbcsr_row_block_sizes (matrix_c),&
                  dbcsr_col_block_sizes (matrix_c),&
                  data_type=dbcsr_get_data_type (matrix_c),&
                  error=dbcsr_error)
             CALL dbcsr_distribution_release (dist_c)
             CALL dbcsr_redistribute (matrix_c, m_c, error=dbcsr_error)
             ! Perform multiply
             CALL mp_sync (group)
             t1 = -m_walltime()
             IF (PRESENT (limits)) THEN
                IF (eps .LE. -0.0_dp) THEN
                   CALL dbcsr_multiply (transa, transb, alpha,&
                        m_a, m_b, beta, m_c,&
                        first_row = limits(1),&
                        last_row = limits(2),&
                        first_column = limits(3),&
                        last_column = limits(4),&
                        first_k = limits(5),&
                        last_k = limits(6),&
                        retain_sparsity=retain_sparsity, flop=flop,&
                        error=dbcsr_error)
                ELSE
                   CALL dbcsr_multiply (transa, transb, alpha,&
                        m_a, m_b, beta, m_c,&
                        first_row = limits(1),&
                        last_row = limits(2),&
                        first_column = limits(3),&
                        last_column = limits(4),&
                        first_k = limits(5),&
                        last_k = limits(6),&
                        retain_sparsity=retain_sparsity, flop=flop,&
                        filter_eps = eps,&
                        error=dbcsr_error)
                ENDIF
             ELSE
                IF (eps .LE. -0.0_dp) THEN
                   CALL dbcsr_multiply (transa, transb, alpha,&
                        m_a, m_b, beta, m_c,&
                        retain_sparsity=retain_sparsity, flop=flop,&
                        error=dbcsr_error)
                ELSE
                   CALL dbcsr_multiply (transa, transb, alpha,&
                        m_a, m_b, beta, m_c,&
                        retain_sparsity=retain_sparsity, flop=flop,&
                        filter_eps = eps,&
                        error=dbcsr_error)
                ENDIF
             ENDIF
             t1 = t1 + m_walltime()
             t2 = t2 + t1
             flop_sum = flop_sum + flop
             !
             CALL dmp_max (t1, group)
             CALL mp_sum (flop, group)
             t1 = MAX (t1, EPSILON (t1))
             flops_all = REAL(flop, KIND=real_8) / t1
             cs = dbcsr_checksum (m_c, error=dbcsr_error)
             cs_pos = dbcsr_checksum (m_c, pos=.TRUE., error=dbcsr_error)
             IF (loop_iter .EQ. 1) THEN
                cs_first = cs
                cs_pos_first = cs_pos
             ENDIF
             ! Release
             CALL dbcsr_mp_release (mp_env)
             CALL dbcsr_release (m_a)
             CALL dbcsr_release (m_b)
             CALL dbcsr_release (m_c)
             IF (io_unit .GT. 0) THEN
                WRITE(io_unit,fmt_per_run_total)&
                     " Loop Multiplication",&
                     numnodes,"processors:",&
                     t1, flops_all, cs, cs_pos
             ENDIF
          ENDIF alive
       ENDDO loops
       IF (i_am_alive) THEN
          CALL dmp_max (t2, group)
          CALL mp_sum (flop_sum, group)
          IF (io_unit .GT. 0) THEN
             t2 = MAX (t2, EPSILON (t2))
             flops_all = REAL(flop_sum, KIND=real_8) / t2
             WRITE(io_unit,fmt_per_run_total)&
                  "Total Multiplication",&
                  numnodes,"processors:",&
                  t2, flops_all, cs_first, cs_pos_first
          ENDIF
       ENDIF
    ENDDO p_sizes
    CALL dbcsr_error_stop (error_handle, error=dbcsr_error)
  END SUBROUTINE test_multiplies_multiproc

END MODULE dbcsr_tests
