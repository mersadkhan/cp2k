!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2011  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief Optimizer for the atomic code
! *****************************************************************************
MODULE atom_optimization
  USE atom_types,                      ONLY: atom_optimization_type
  USE f77_blas
  USE kinds,                           ONLY: dp
  USE lapack,                          ONLY: lapack_sgelss
#include "cp_common_uses.h"

  IMPLICIT NONE

  PRIVATE

  CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'atom_optimization'

  TYPE hmat_type
    REAL(dp),DIMENSION(:,:,:),POINTER     :: emat
    REAL(dp),DIMENSION(:,:,:),POINTER     :: fmat
  END TYPE hmat_type

  TYPE atom_history_type
    INTEGER                               :: max_history
    INTEGER                               :: hlen
    INTEGER                               :: hpos
    REAL(dp)                              :: damping
    REAL(dp)                              :: eps_diis
    REAL(dp),DIMENSION(:,:),POINTER       :: dmat
    TYPE(hmat_type),DIMENSION(:),POINTER  :: hmat
  END TYPE atom_history_type

  PUBLIC :: atom_opt, hmat_type, &
            atom_history_type, atom_history_init, atom_history_update, atom_history_release

! *****************************************************************************

CONTAINS

! *****************************************************************************
  SUBROUTINE atom_history_init (history,optimization,matrix,error)
    TYPE(atom_history_type), INTENT(INOUT)   :: history
    TYPE(atom_optimization_type), INTENT(IN) :: optimization
    REAL(dp), DIMENSION(:, :, :), INTENT(IN) :: matrix
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'atom_history_init', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: i, ierr, n1, n2, n3, ndiis
    LOGICAL                                  :: failure = .FALSE.
    REAL(dp)                                 :: damp, eps

    ndiis = optimization%n_diis
    eps   = optimization%eps_diis
    damp  = optimization%damping

    CALL atom_history_release (history,error)

    history%max_history = ndiis
    history%hlen = 0
    history%hpos = 0
    history%damping = damp
    history%eps_diis = eps
    ALLOCATE ( history%dmat(ndiis+1,ndiis+1), STAT=ierr )
    CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)

    ALLOCATE ( history%hmat(ndiis), STAT=ierr )
    CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
    n1 = SIZE(matrix,1)
    n2 = SIZE(matrix,2)
    n3 = SIZE(matrix,3)
    DO i=1,ndiis
      ALLOCATE ( history%hmat(i)%emat(n1,n2,n3), STAT=ierr )
      CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
      ALLOCATE ( history%hmat(i)%fmat(n1,n2,n3), STAT=ierr )
      CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
    END DO

  END SUBROUTINE atom_history_init
! *****************************************************************************
  SUBROUTINE atom_history_update (history,fmat,emat,error)
    TYPE(atom_history_type), INTENT(INOUT)   :: history
    REAL(dp), DIMENSION(:, :, :), INTENT(IN) :: fmat, emat
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'atom_history_update', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: nlen, nmax, nnow

    nmax = history%max_history 
    nlen = MIN (history%hlen + 1, nmax)
    nnow = history%hpos + 1
    IF (nnow > nmax) nnow = 1

    history%hmat(nnow)%fmat = fmat
    history%hmat(nnow)%emat = emat

    history%hlen = nlen
    history%hpos = nnow

  END SUBROUTINE atom_history_update
! *****************************************************************************
  SUBROUTINE atom_history_release (history,error)
    TYPE(atom_history_type), INTENT(INOUT)   :: history
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'atom_history_release', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: i, ierr
    LOGICAL                                  :: failure = .FALSE.

    history%max_history = 0
    history%hlen = 0
    history%hpos = 0
    history%damping = 0._dp
    history%eps_diis = 0._dp
    IF ( ASSOCIATED(history%dmat) ) THEN
      DEALLOCATE ( history%dmat, STAT=ierr )
      CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
      NULLIFY ( history%dmat )
    END IF
    IF ( ASSOCIATED(history%hmat) ) THEN
      DO i=1,SIZE(history%hmat)
        IF ( ASSOCIATED(history%hmat(i)%emat) ) THEN
          DEALLOCATE ( history%hmat(i)%emat, STAT=ierr )
          CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
          NULLIFY ( history%hmat(i)%emat )
        END IF
        IF ( ASSOCIATED(history%hmat(i)%fmat) ) THEN
          DEALLOCATE ( history%hmat(i)%fmat, STAT=ierr )
          CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
          NULLIFY ( history%hmat(i)%fmat )
        END IF
      END DO
      DEALLOCATE ( history%hmat, STAT=ierr )
      CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
      NULLIFY ( history%hmat )
    END IF

  END SUBROUTINE atom_history_release
! *****************************************************************************
  SUBROUTINE atom_opt (fmat,history,err,error)
    REAL(dp), DIMENSION(:, :, :), &
      INTENT(INOUT)                          :: fmat
    TYPE(atom_history_type), INTENT(INOUT)   :: history
    REAL(dp), INTENT(IN)                     :: err
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'atom_opt', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: i, ierr, info, j, lwork, na, &
                                                nb, nlen, nm, nmax, nnow, rank
    LOGICAL                                  :: failure = .FALSE.
    REAL(dp)                                 :: a, rcond, t
    REAL(dp), ALLOCATABLE, DIMENSION(:)      :: s, work
    REAL(dp), ALLOCATABLE, DIMENSION(:, :)   :: vec

    nmax = history%max_history 
    nnow = history%hpos
    a = history%damping
    IF ( history%hlen > 1 ) THEN
      IF ( err < history%eps_diis ) THEN
        ! DIIS
        rcond = 1.e-10_dp
        lwork = 25*nmax
        ALLOCATE(vec(nmax+1,2),s(nmax+1),work(lwork),STAT=ierr)
        CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
        nlen = history%hlen
        vec = 0._dp
        vec(nlen+1,1) = 1._dp
        history%dmat(1:nlen,nlen+1) = 1._dp
        history%dmat(nlen+1,1:nlen) = 1._dp
        history%dmat(nlen+1,nlen+1) = 0._dp
        DO i=1,nlen
          na = nnow + 1 - i
          IF ( na < 1 ) na = nmax + na
          DO j=i,nlen
            nb = nnow + 1 - j
            IF ( nb < 1 ) nb = nmax + nb
            t = SUM(history%hmat(na)%emat*history%hmat(nb)%emat)
            history%dmat(i,j) = t
            history%dmat(j,i) = t
          END DO
        END DO
        CALL lapack_sgelss(nlen+1,nlen+1,1,history%dmat,nmax+1,vec,nmax+1,s,&
                           rcond,rank,work,lwork,info)
        CPPostcondition(info==0,cp_failure_level,routineP,error,failure)
        fmat = 0._dp
        DO i=1,nlen
          na = nnow + 1 - i
          IF ( na < 1 ) na = nmax + na
          fmat = fmat + vec(i,1)*history%hmat(na)%fmat
        END DO

        DEALLOCATE(vec,s,work,STAT=ierr)
        CPPostcondition(ierr==0,cp_failure_level,routineP,error,failure)
      ELSE
        ! damping
        nm = nnow - 1
        IF ( nm < 1 ) nm = history%max_history
        fmat = a*history%hmat(nnow)%fmat + (1._dp - a)*history%hmat(nm)%fmat
      END IF
    ELSEIF ( history%hlen == 1 ) THEN
      fmat = history%hmat(nnow)%fmat 
    ELSE
      CPPostcondition(.FALSE.,cp_failure_level,routineP,error,failure)
    END IF

  END SUBROUTINE atom_opt
! *****************************************************************************

END MODULE atom_optimization
