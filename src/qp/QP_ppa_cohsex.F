!
! License-Identifier: GPL
!
! Copyright (C) 2006 The Yambo Team
!
! Authors (see AUTHORS file for details): AM
!
subroutine QP_ppa_cohsex(X,Xk,E,k,q,qp,Xw,W,GW_iter)
 !
 ! Plasmon Pole & COHSEX Correlation Self-Energy
 !
 use pars,          ONLY:DP,SP,pi,schlen,cZERO,cI
 use units,         ONLY:HA2EV
 use stderr,        ONLY:intc
 use frequency,     ONLY:w_samp
 use electrons,     ONLY:levels,spin_occ,spin,n_met_bands,n_sp_pol
 use LIVE_t,        ONLY:live_timing
 use com,           ONLY:msg
 use drivers,       ONLY:l_ppa,l_cohsex,l_sc_srpa,l_sc_sex,l_sc_coh,l_sc_run,&
&                        l_rt_carriers_in_use,l_rim_w
 use parallel_int,  ONLY:PP_wait,PP_redux_wait,PARALLEL_global_indexes,PARALLEL_WF_index,&
&                        PARALLEL_WF_distribute
 use parallel_m,    ONLY:PAR_IND_Xk_ibz,PAR_IND_G_b,PAR_IND_QP,&
&                        PAR_IND_Q_ibz,PAR_IND_Q_ibz_ID,PAR_IND_QP_ID,&
&                        PAR_Q_ibz_index,n_WF_bands_to_load,HEAD_QP_cpu
 use collision_el,  ONLY:elemental_collision,elemental_collision_free,elemental_collision_alloc
 use functions,     ONLY:bose_f
 use IO_int,        ONLY:io_control
 use IO_m,          ONLY:manage_action,OP_RD_CL,REP,VERIFY,NONE,OP_RD,RD_CL_IF_END,&
&                        io_RESPONSE,deliver_IO_error_message
 use QP_m,          ONLY:QP_t,QP_n_G_bands,QP_dSc_steps,QP_table,l_QP_symmetrize,&
&                        QP_Sc,QP_n_states,QP_G_damp,QP_table,QP_dSc_delta,&
&                        COHSEX_use_empties,l_GW_terminator,GW_terminator_Kind,QP_states_simmetrize
 use X_m,           ONLY:X_ALLOC_elemental,X_mat,X_mat_d,X_t
 use wave_func,     ONLY:WF
 use R_lattice,     ONLY:qindx_S,bz_samp,G_m_G,nqibz,RIM_W_E,&
&                        RIM_W_is_diagonal,RIM_W_ng,RIM_W,RIM_W_d
 use D_lattice,     ONLY:nsym,i_time_rev,i_space_inv,mag_syms
 use wrapper,       ONLY:M_by_V
 use interfaces,    ONLY:QP_state_print,WF_load,WF_free
 use matrix_operate,ONLY:mat_transpose
 use timing_m,      ONLY:timing
#if defined _SC
 use parallel_m,    ONLY:PAR_COM_QP_A2A
 use SC,            ONLY:it_now,it_to_start
#endif
 use deviceXlib_m,  ONLY:dev_memcpy
 use cuda_m,        ONLY:have_cuda
#ifdef _CUDA
 use drivers,       ONLY:Finite_Tel
 use D_lattice,     ONLY:Bose_Temp
 use functions,     ONLY:bose_E_cut
#endif
 !
#include<dev_defs.h>
#include<memory.h>
 !
 type(levels) ::E
 type(bz_samp)::Xk,k,q
 type(X_t)    ::X
 type(QP_t)   ::qp
 type(w_samp) ::Xw
 integer      ::GW_iter
 !
 ! DALV: this is the frequency grid for Sc,
 !       now set in the solvers('n','s','g')
 !
 real(SP),intent(in) ::W(QP_dSc_steps)
 !
 ! Work Space
 !
 integer                  ::i_qp,i_w,iqbz,iqibz,ib,ig1,ig2,alloc_err,iqs,iscs_save(2,4),&
&                           i_qp_to_start,iq_to_start,is,iq_mem,X_range(2),io_err,ID,IO_ACT,timing_steps
 complex(SP), allocatable ::W_(:),dc(:),eet_factor(:,:)
 type(elemental_collision),target ::isc,iscp
 character(schlen)::ch,SECTION_name,W_name
 !
 logical          ::X_is_TR_rotated,l_X_ALLOC_elemental,l_RIM_W_g
 real(SP)         ::eet_cutoff0(n_sp_pol),E_kmq,f_kmq,eet_cutoff1(n_sp_pol),PPA_E
 complex(SP)      ::PPA_R,local_rhotw(X%ng),pre_factor
 complex(DP)      ::dp_dummy,ctmp
 !
#ifdef _CUDA
 integer                      :: Xng, Xr1, Xr2
 real(SP)                     :: XppaE, bose_PPA_E
 real(DP)                     :: dp_dummy_r, dp_dummy_i
 complex(SP)                  :: W_i_w
 complex(SP), pointer, device :: isc_rhotw_d(:)
 complex(SP), pointer, device :: iscp_rhotw_d(:)
 complex(SP), pointer, device :: isc_gamp_d(:,:)
#endif
 !
 integer,     external ::io_X
 complex(SP), external ::QP_ppa_EET_terminator
 !
 integer      :: first_el(QP_n_states),n_of_el(QP_n_states),n_deg_grp,i_c
 integer      :: PPcond_rate,TO_rate
 real(SP)     :: PP_err
 !
 ! Reset & checks
 !
 call elemental_collision_free(isc)
 call elemental_collision_free(iscp)
 i_qp_to_start=1
 iq_to_start  =1
 QP_Sc        =cZERO
 !
 if (l_GW_terminator.and.trim(GW_terminator_Kind)/='BG'.and.&
&    trim(GW_terminator_Kind)/='BRS') &
&    call error(' [GW/PPA] unknown GW_terminator_Kind = '//trim(GW_terminator_Kind))
 !
 ! COHSEX: bands setup
 !
 if ((l_sc_srpa.or.l_cohsex.or.l_sc_coh.or.l_sc_sex  ).and.(.not.COHSEX_use_empties)) then
   QP_n_G_bands(2)=max(maxval(QP_table(:,:2)),maxval(n_met_bands))
 endif
 !
 ! Section
 !
 SECTION_name=''
#if defined _SC
 if (l_sc_coh) SECTION_name=trim(SECTION_name)//'COH'
 if (l_sc_sex) SECTION_name=trim(SECTION_name)//'SEX'
#endif
 if (.not.l_sc_run) then
   SECTION_name='G'//trim(intc(GW_iter))
   W_name      ='W0'
   if (                    l_cohsex) SECTION_name=trim(SECTION_name)//trim(W_name)//' (COHSEX)'
   if (     l_ppa                  ) SECTION_name=trim(SECTION_name)//trim(W_name)//' (W PPA)'
   if (.not.l_ppa.and..not.l_cohsex) SECTION_name=trim(SECTION_name)//trim(W_name)//' (W real-axis)'
 endif
 !
 if (GW_iter==0) then
   if(l_rim_w) then
     call section('-',trim(SECTION_name))
   else
     call section('+',trim(SECTION_name))
   end if
 end if
 if (GW_iter > 0) call section('=',trim(SECTION_name))
 !
 if (GW_iter==0) then
   call msg('r', '[  GW  ] Bands range     ',QP_n_G_bands)
   if (l_ppa) then
     call msg('r', '[GW/PPA] G damping       ',QP_G_damp*HA2EV,"[eV]")
     call msg('r','')
   endif
   ch=trim(SECTION_name)
   !
   call QP_state_print( )
   !
 endif
 !
 call k_expand(k)
 !
 ! WF distributed & load
 !=======================
 !
 if ( .not.l_sc_run ) call PARALLEL_global_indexes(E,k,q,"Self_Energy")
 !
 ! Redefine iq_to_start to be CPU-dependent
 !
 do iqbz=1,q%nbz 
   if (PAR_IND_Q_ibz%element_1D(q%sstar(iqbz,1))) then
     iq_to_start=iqbz
     exit
   endif
 enddo
 !
 if( .not.l_sc_run ) then
   call PARALLEL_WF_distribute(K_index=PAR_IND_Xk_ibz,B_index=PAR_IND_G_b,CLEAN_UP=.TRUE.)
   call PARALLEL_WF_distribute(QP_index=PAR_IND_QP)
   call PARALLEL_WF_index( )
 endif
 !
 ch='-GW'
#if defined _SC
 if(l_sc_run) ch='-SC'
#endif
 !
 ! wf and collisions dimension
 !-----------------------------
 isc%ngrho=X%ng
 if (((l_sc_srpa.or.l_cohsex.or.l_sc_coh).and..not.COHSEX_use_empties).or.l_GW_terminator) isc%ngrho=maxval(G_m_G)
 !
 call WF_load(WF,isc%ngrho,maxval(qindx_S(:,:,2)),(/1,n_WF_bands_to_load/),(/1,k%nibz/),title=trim(ch))
 !
 ! Elemental Collisions
 !====================== 
 isc%iqref=0
 call elemental_collision_alloc(isc,NG=isc%ngrho,NG_GAMP=(/X%ng,X%ng/),TITLE="GW")
 call elemental_collision_alloc(iscp,NG=isc%ngrho,TITLE="GW")
 !
 call timing('GW(ppa)',OPR='start')
 !
 ! Plasmon-Pole/Static interaction DB I/O
 !
 call io_control(ACTION=OP_RD_CL,COM=REP,SEC=(/1,2/),MODE=VERIFY,ID=ID)
 io_err=io_X(X,Xw,ID)
 if (io_err<0.and.io_RESPONSE) call error('Incomplete and/or broken PPA/Static diel. fun. database')
 !
 ! Test the spatial Inversion
 !   
 call WF_spatial_inversion(E,Xk)
 !
 ! ALLOCATION
 !------------
 !
 if (l_sc_coh.or.l_sc_sex.or.l_cohsex.or.l_sc_srpa) then
   if (io_RESPONSE) call X_ALLOC_elemental('X',(/X%ng,X%ng,1/))
   allocate(dc(2))
 else
   if (io_RESPONSE) call X_ALLOC_elemental('X',(/X%ng,X%ng,2/))
   allocate(W_(QP_dSc_steps))
   allocate(dc(QP_dSc_steps),stat=alloc_err)
   if(l_GW_terminator) then
     YAMBO_ALLOC(eet_factor,(X%ng,X%ng))
   endif
 endif
 !
 call PP_wait()
 !
 timing_steps=PAR_IND_QP%n_of_elements(PAR_IND_QP_ID+1)*&
&             PAR_IND_Q_ibz%n_of_elements(PAR_IND_Q_ibz_ID+1)*&
&             count( PAR_IND_G_b%element_1D(QP_n_G_bands(1):QP_n_G_bands(2)) )
 !
 ch=trim(SECTION_name)
#if defined _SC
 if (l_sc_run) ch=trim(SECTION_name)//'@it'//trim(intc(it_now))
#endif
 call live_timing(trim(ch),timing_steps)
 !
 if (io_RESPONSE) then
   call io_control(ACTION=OP_RD,COM=NONE,SEC=(/1/),ID=ID)
   io_err=io_X(X,Xw,ID)
 endif
 !
 Q_loop: do iqbz=iq_to_start,q%nbz
   !
   if (.not.PAR_IND_Q_ibz%element_1D(q%sstar(iqbz,1))) cycle
   !
   isc%qs(2:)=(/q%sstar(iqbz,1),q%sstar(iqbz,2)/)
   iqibz=isc%qs(2)
   iqs  =isc%qs(3)
   !
   if (iqibz/=isc%iqref) then
     !
     iq_mem=PAR_Q_ibz_index(iqibz)
     X_range=(/1,Xw%n_freqs/)
     if (.not.io_RESPONSE) X_range=(/Xw%n_freqs*(iq_mem-1)+1,iq_mem*Xw%n_freqs/)
     !
     call DEV_SUB(scatter_Gamp)(isc,'c')
     if (have_cuda) call dev_memcpy(isc%gamp,isc%gamp_d)
     !
     ! I/O
     !
     if (io_RESPONSE) then
       !
       IO_ACT=manage_action(RD_CL_IF_END,iqibz,iq_to_start,nqibz,PAR_INDEX=PAR_IND_Q_ibz)
       call io_control(ACTION=IO_ACT,COM=NONE,SEC=(/2*iqibz,2*iqibz+1/),ID=ID)
       io_err=io_X(X,Xw,ID)
       !
       call deliver_IO_error_message(io_err,'PP/Em1s',STOP_it=.TRUE.)
       !
     endif
     !
     ! Poles and Residuals
     !
     ! DV comment:
     ! When cutoff is used, here a careful check is needed.
     ! Because of qpg can be imaginary, also are some component of X_mat, I am not sure
     ! that the definition here below of X_mat(ig1,ig2,:) is correct.
     !
#if defined _SC
     if (l_sc_run .and. it_now==it_to_start.or.io_RESPONSE) then
#endif
       !
       PPcond_rate=0
       TO_rate=0
       PP_err=0.0_SP
       !
       !$omp     parallel do default(shared), private(ig1,ig2,l_RIM_W_g), &
       !$omp &   reduction(+:PPcond_rate,TO_rate,PP_err), collapse(2)
       do ig2=1,X%ng
         do ig1=1,X%ng
           !
           if (l_ppa) then
             !
             ! RIM W support
             !
             l_RIM_W_g=(l_rim_w.and.ig1<=RIM_W_ng.and.ig2<=RIM_W_ng.and.iqibz==1)
             if (RIM_W_is_diagonal.and.l_RIM_W_g) l_RIM_W_g=(ig1==ig2)
             !
             if (l_RIM_W_g) then
               !
               X_mat(ig1,ig2,X_range(2))=RIM_W_E(ig1,ig2)
               !
             else
               !
               if (real(X_mat(ig1,ig2,X_range(1))/X_mat(ig1,ig2,X_range(2)))<=1._SP) then
                 !
                 X_mat(ig1,ig2,X_range(2))=X%ppaE
                 !
                 PP_err=PP_err+abs(X_mat(ig1,ig2,X_range(1))/(X%ppaE**2+1._SP)-X_mat(ig1,ig2,X_range(2)) )/&
&                              maxval(abs(X_mat(ig1,ig2,X_range(:2))))
                 PPcond_rate=PPcond_rate+1
               else
                 !
                 X_mat(ig1,ig2,X_range(2))=sqrt(X_mat(ig1,ig2,X_range(1))/X_mat(ig1,ig2,X_range(2))-1)
                 !
                 if(real(1._SP/X_mat(ig1,ig2,X_range(2)),SP)*aimag(1._SP/X_mat(ig1,ig2,X_range(2)))>0._SP) then
                   TO_rate=TO_rate+1
                 endif
               endif
               !
             endif
             !
           else
             !
             ! COHSEX
             !
             X_mat(ig1,ig2,X_range(1))=X_mat(ig1,ig2,X_range(1))*isc%gamp(ig1,ig2)
           endif
           !
         enddo
       enddo
       !$omp end parallel do
       !
       call msg('r',' Current Q-pt index             ',iqibz)
       call msg('r',' :: PP condition fails/total    ',real(PPcond_rate,SP)/X%ng**2)
       call msg('r',' :: Time ordering fails/rest    ',real(TO_rate,SP)/(X%ng**2-PPcond_rate))
       call msg('r',' :: Mean rel dev of PP cond     ',PP_err/X%ng**2)
       !
#if defined _SC
     endif
#endif
     !
     X_is_TR_rotated=.false.
     !
   endif
   !
   ! This additional rotation of the PP residuals arised from the particular
   ! case when TR is present but not the spatial inversion.
   ! In this case, indeed, 
   !
   !   X(-q,G,G') = X(q,-G',-G)
   !
   ! While the -1 is introduced in the collisions the reflection of the
   ! matrix must be done here.
   !
   if (iqs>nsym/(i_time_rev+1) .and. (i_space_inv==0.or.mag_syms) .and..not.X_is_TR_rotated) then
     !
     ! Note (AF) that $omp directives are inside mat_transpose
     !
     call mat_transpose(X_mat(:,:,X_range(1)))
     if (l_ppa) call mat_transpose(X_mat(:,:,X_range(2)))
     X_is_TR_rotated=.true.
   endif
   !
   if (have_cuda) call dev_memcpy(X_mat_d, X_mat)
   !
   QP_loop: do i_qp=i_qp_to_start,QP_n_states
     !
     if (.not.PAR_IND_QP%element_1D(i_qp)) cycle
     !
     ! i_qp must start from i_qp_to_start only during the first loop
     ! of the restart. Then it must be set to 1.
     !
     if (i_qp==QP_n_states) i_qp_to_start=1
     !
!#if defined _SC  
!     !
!     ! In OEP only vc matrix elements so ... no cc' no vv' 
!     ! (cv is not permitted by the order in QP_table)
!     !                       (c)         (v)
!     if (l_sc_srpa.and.(QP_table(i_qp,1)>E%nbf.or.QP_table(i_qp,2)<=E%nbf)) cycle
!#endif
     !
     isc%is=(/QP_table(i_qp,1),QP_table(i_qp,3),1,spin(QP_table(i_qp,:))/)
     isc%os(2:)=(/k%sstar(qindx_S(isc%is(2),iqbz,1),:),spin(QP_table(i_qp,:))/)
     isc%qs(1)=qindx_S(QP_table(i_qp,3),iqbz,2)
     !
     iscp%is=(/QP_table(i_qp,2),QP_table(i_qp,3),1,spin(QP_table(i_qp,:))/)
     iscp%qs=isc%qs
     !
     dc=cZERO
     !
     ! COH (using completeness relation)
     !
     if (((l_sc_srpa.or.l_sc_coh.or.l_cohsex).and..not.COHSEX_use_empties).or.l_GW_terminator) then
       !
       iscs_save(1,: )=isc%os
       iscs_save(2,:3)=isc%qs
       isc%os=(/QP_table(i_qp,2),QP_table(i_qp,3),1,spin(QP_table(i_qp,:))/)
       isc%qs=(/1,1,1/)

       call DEV_SUB(scatter_Bamp)(isc)
       if (have_cuda) call dev_memcpy(isc%rhotw,isc%rhotw_d)
       !
       if (l_GW_terminator) then
         do is=1,n_sp_pol
           eet_cutoff0(is)=minval(E%E(E%nbf(is)+1,:,is))
           eet_cutoff1(is)=minval(E%E(QP_n_G_bands(2),:,is))
         enddo
         eet_cutoff0(1)=minval(eet_cutoff0(:))
         eet_cutoff1(1)=minval(eet_cutoff1(:))
         eet_factor=cZERO
         !
         if ( HEAD_QP_cpu ) then
           if (X_is_TR_rotated) then
              !$omp parallel do default(shared), private(ig1,ig2)
              do ig2=1,X%ng
                do ig1=1,X%ng
                  eet_factor(ig1,ig2)=isc%rhotw(G_m_G(ig2,ig1))
                enddo
              enddo
              !$omp end parallel do
           else
              !$omp parallel do default(shared), private(ig1,ig2)
              do ig2=1,X%ng
                do ig1=1,X%ng
                  eet_factor(ig1,ig2)=isc%rhotw(G_m_G(ig1,ig2))
                enddo
              enddo
              !$omp end parallel do
           endif
         endif
         !
       else
         !
         dp_dummy = 0.0_DP
         !
         if (X_is_TR_rotated) then
           !$omp parallel do default(shared), private(ig1,ig2), reduction(+:dp_dummy)
           do ig2=1,X%ng
             do ig1=1,X%ng
               dp_dummy=dp_dummy+cmplx(2._SP*pi*isc%rhotw(G_m_G(ig2,ig1))*X_mat(ig1,ig2,X_range(1)),kind=DP)
             enddo
           enddo
           !$omp end parallel do
         else
           !$omp parallel do default(shared), private(ig1,ig2), reduction(+:dp_dummy)
           do ig2=1,X%ng
             do ig1=1,X%ng
               dp_dummy=dp_dummy+cmplx(2._SP*pi*isc%rhotw(G_m_G(ig1,ig2))*X_mat(ig1,ig2,X_range(1)),kind=DP)
             enddo
           enddo
           !$omp end parallel do
         endif
         !
         dc(1) = cmplx(dp_dummy,kind=SP)
         !
         ! Bug spotted by D.V. (April 2014). HEAD_QP_cpu is defined differently when
         ! the _SC flag is used. The point is that in SE calculations HEAD_QP_cpu is used
         ! in cases where no band loops are done (like here). In _SC instead 
         ! it is needed for a different purpose. This is why I use PAR_COM_QP_A2A%CPU_id in this case.
         !
#if defined _SC
         if (l_sc_run) then
           if (PAR_COM_QP_A2A%CPU_id==0) QP_Sc(i_qp,:)=QP_Sc(i_qp,:)+dc(1)
         else
#endif
           if (HEAD_QP_cpu)              QP_Sc(i_qp,:)=QP_Sc(i_qp,:)+dc(1)
#if defined _SC
         endif
#endif
         !
         dc=cZERO
         !
       endif
       !
       isc%os=iscs_save(1,: )
       isc%qs=iscs_save(2,:3)
       !
     endif
     !
     do ib=QP_n_G_bands(1),QP_n_G_bands(2)
       !
       if (.not.PAR_IND_G_b%element_1D(ib)) cycle
       !
       if (q%sstar(iqbz,2)==1) call live_timing(steps=1)
       !
       isc%os(1)=ib
       !
       call DEV_SUB(scatter_Bamp)(isc)
       if (have_cuda) call dev_memcpy(isc%rhotw, isc%rhotw_d)
       iscp%os=isc%os
       !
       if (any(isc%is/=iscp%is)) then
         call DEV_SUB(scatter_Bamp)(iscp)
         if (have_cuda) call dev_memcpy(iscp%rhotw, iscp%rhotw_d)
       else
         iscp%rhotw=isc%rhotw
         if (have_cuda) call dev_memcpy(iscp%rhotw_d, iscp%rhotw)
       endif
       !
       dc=cZERO
       !
       if (l_ppa) then
         !
         if(l_GW_terminator) then
           !$omp parallel do default(shared), private(ig1,ig2)
           do ig2=1,X%ng
             do ig1=1,X%ng
                 eet_factor(ig1,ig2)=eet_factor(ig1,ig2)-isc%rhotw(ig1)*conjg(iscp%rhotw(ig2))
             enddo
           enddo
           !$omp end parallel do
         endif
         !
         ! DALV: here the grid is center in E0
         forall (i_w=1:QP_dSc_steps) W_(i_w)=qp%E(i_qp)+W(i_w)+cI*QP_G_damp 
         !
         E_kmq=E%E(isc%os(1),isc%os(2),isc%os(4))
         f_kmq=E%f(isc%os(1),isc%os(2),isc%os(4))
         !
#ifdef _CUDA
         Xng = X%ng
         XppaE = X%ppaE
         Xr1 = X_range(1)
         Xr2 = X_range(2)

         isc_gamp_d => isc%gamp_d
         isc_rhotw_d => isc%rhotw_d
         iscp_rhotw_d => iscp%rhotw_d

         do i_w=1,QP_dSc_steps
           W_i_w = W_(i_w)
           !
           ! NOTE: Split reduction done here to work around PGI bug with complex
           ! CUF reductions.
           dp_dummy_r = 0.0_DP
           dp_dummy_i = 0.0_DP
           !
           !$cuf kernel do(2)
           do ig2=1,Xng
             do ig1=1,Xng
               !
               PPA_E= real(XppaE/X_mat_d(ig1,ig2,Xr2),kind=SP)
               !
               ! RIM W support
               !
               l_RIM_W_g=(l_rim_w.and.ig1<=RIM_W_ng.and.ig2<=RIM_W_ng)
               if (RIM_W_is_diagonal.and.l_RIM_W_g) l_RIM_W_g=(ig1==ig2)
               !
               if (l_RIM_W_g) then
                 PPA_R=-cmplx(RIM_W_d(iqibz,ig1,ig2)/2._SP, &
&                             aimag(X_mat_d(ig1,ig2,Xr1))*real(isc_gamp_d(ig1,ig2)),kind=SP)/2._SP*PPA_E
               else
                 PPA_R=-X_mat_d(ig1,ig2,Xr1)/2._SP*PPA_E*isc_gamp_d(ig1,ig2)
               endif
               !
               ! inline bose_f function
               bose_PPA_E=0.
               if (PPA_E<0.) bose_PPA_E=-spin_occ
               if (Finite_Tel) then
                 if (abs(PPA_E)>epsilon(1.)) then
                   if (abs(PPA_E)<=bose_E_cut*Bose_Temp) bose_PPA_E=spin_occ*Bose_Temp/PPA_E
                   if (abs(PPA_E)> bose_E_cut*Bose_Temp) bose_PPA_E=spin_occ/(exp(PPA_E/Bose_Temp)-1.)
                 else
                   bose_PPA_E=spin_occ*Bose_Temp/epsilon(1.)
                 endif
               endif
               !
               ctmp = -4._SP/spin_occ*pi*isc_rhotw_d(ig1)*conjg(iscp_rhotw_d(ig2))*(-PPA_R)*&
&                     ( (spin_occ-f_kmq+bose_PPA_E)/(W_i_w-E_kmq-PPA_E)+&
&                       (f_kmq+bose_PPA_E)/(conjg(W_i_w)-E_kmq+PPA_E))
               !
               dp_dummy_r=dp_dummy_r+real(ctmp)   ! real(ctmp,DP)
               dp_dummy_i=dp_dummy_i+imag(ctmp)
               !
             enddo
           enddo
           !
           dp_dummy%re = dp_dummy_r
           dp_dummy%im = dp_dummy_i
           dc(i_w) = cmplx(dp_dummy,kind=SP)
           !
         enddo
#else
         do i_w=1,QP_dSc_steps
           !
           dp_dummy = 0.0_DP
           !
           !$omp parallel do default(shared), private(ig1,ig2,PPA_E,PPA_R,ctmp, &
           !$omp &           l_RIM_W_g), reduction(+:dp_dummy)
           do ig2=1,X%ng
             do ig1=1,X%ng
               !
               PPA_E= real(X%ppaE/X_mat(ig1,ig2,X_range(2)),kind=SP)
               !
               ! RIM W support
               !
               l_RIM_W_g=(l_RIM_W.and.ig1<=RIM_W_ng.and.ig2<=RIM_W_ng)
               if (RIM_W_is_diagonal.and.l_RIM_W_g) l_RIM_W_g=(ig1==ig2)
               !
               if (l_RIM_W_g) then
                 PPA_R=-cmplx(RIM_W(iqibz,ig1,ig2)/2._SP, &
&                       aimag(X_mat(ig1,ig2,X_range(1)))*real(isc%gamp(ig1,ig2),kind=SP),kind=SP)/2._SP*PPA_E
               else
                 PPA_R=-X_mat(ig1,ig2,X_range(1))/2._SP*PPA_E*isc%gamp(ig1,ig2)
               end if
               !
               ctmp = -4._SP/spin_occ*pi*isc%rhotw(ig1)*conjg(iscp%rhotw(ig2))*(-PPA_R)*&
&                     ( (spin_occ-f_kmq+bose_f(PPA_E))/(W_(i_w)-E_kmq-PPA_E)+&
&                       (f_kmq+bose_f(PPA_E))/(conjg(W_(i_w))-E_kmq+PPA_E))
               !
               dp_dummy=dp_dummy+ctmp
               !
             enddo
           enddo
           !$omp end parallel do
           !
           dc(i_w) = cmplx(dp_dummy,kind=SP)
           !
         enddo
#endif
         !
         QP_Sc(i_qp,:QP_dSc_steps)=QP_Sc(i_qp,:QP_dSc_steps)+dc(:QP_dSc_steps)
         !
       else if (l_sc_sex.or.l_cohsex.or.(l_sc_coh.and.COHSEX_use_empties)) then
         !
         call M_by_V('N', X%ng, X_mat(:,:,X_range(1)), conjg(iscp%rhotw), local_rhotw)
         !
         pre_factor=0.0_SP
         !$omp parallel do default(shared), private(ig1), reduction(+:pre_factor)
         do ig1=1,X%ng
           pre_factor=pre_factor+isc%rhotw(ig1)*local_rhotw(ig1)
         enddo
         !$omp end parallel do

         !
         ! SEX
         !
         if (l_sc_sex.or.l_cohsex) dc(1)=-4._SP/spin_occ*pi*pre_factor*e%f(isc%os(1),isc%os(2),isc%os(4))
         !
         ! COH (when no empties are used the COH part is indeed calculated above)
         !
         if (COHSEX_use_empties) then
           if (l_sc_coh.or.l_cohsex) dc(2)=2._SP*pi*pre_factor
         endif
         !
         QP_Sc(i_qp,:)=QP_Sc(i_qp,:)+dc(1)+dc(2)
         !
       endif
       !
     enddo ! loop on scattering states
     !
     if(l_GW_terminator) then
       !
       ! DALV: here the grid is center in E0
       forall (i_w=1:QP_dSc_steps) W_(i_w)=qp%E(i_qp)+W(i_w)+cI*QP_G_damp 
       !
       do i_w=1,QP_dSc_steps
         !
         dp_dummy=0.0_DP
         !
         !$omp parallel do default(shared), private(ig1,ig2,PPA_E,PPA_R), reduction(+:dp_dummy)
         do ig2=1,X%ng
           do ig1=1,X%ng
             !
             PPA_E=X%ppaE/real(X_mat(ig1,ig2,X_range(2)))
             PPA_R=-X_mat(ig1,ig2,X_range(1))/2._SP*PPA_E*isc%gamp(ig1,ig2)
             !
             dp_dummy=dp_dummy +cmplx(4._SP/spin_occ*pi*PPA_R*eet_factor(ig1,ig2)* &
&                         QP_ppa_EET_terminator(W_(i_w),E,isc%is,PPA_E,ig1,ig2,isc%qs(2),&
&                                               eet_cutoff0(1),eet_cutoff1(1)),kind=DP)
             !
           enddo
         enddo
         !$omp end parallel do
         !
         QP_Sc(i_qp,i_w)=QP_Sc(i_qp,i_w)+cmplx(dp_dummy,kind=SP)
         !
       enddo
       !
     endif
     !
   enddo QP_loop
   !
 enddo Q_loop 
 !
 call live_timing()
 !
 ! CLEAN
 !
 deallocate(dc)
 if(l_ppa) then
   deallocate(W_)
   if (l_GW_terminator) then
     YAMBO_FREE(eet_factor)
   endif
 endif
 l_X_ALLOC_elemental=.true.
#if defined _SC
 l_X_ALLOC_elemental=l_sc_run.and.io_RESPONSE
#endif
 if(l_X_ALLOC_elemental) call X_ALLOC_elemental('X')
 !
 call timing('GW(ppa)',OPR='stop')
 !
 if (.not.l_sc_run) call WF_free(WF)
 !
 call elemental_collision_free(isc)
 call elemental_collision_free(iscp)
 !
 ! ALL 2 ALL of QP_Sc
 !
 call timing('GW(REDUX)',OPR='start')
 call PP_redux_wait(QP_Sc)
 call timing('GW(REDUX)',OPR='stop')
 !
 ! AM, Sept 2019. The COH potential seems to break (in some case of a large amount) the
 ! energy degenerations. 
 !
 if (.not.l_sc_run.and..not.l_rt_carriers_in_use.and.l_QP_symmetrize) then
   do i_w=1,QP_dSc_steps
     if (i_w==1) call QP_states_simmetrize(E,what="COHSEX Sc",V_complex=QP_Sc(:,1),warn_me=.TRUE.)
     if (i_w> 1) call QP_states_simmetrize(E,V_complex=QP_Sc(:,i_w))
   enddo
 endif
 !
end subroutine
