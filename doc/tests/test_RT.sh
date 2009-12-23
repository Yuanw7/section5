#!/bin/bash

EPS=0.00005   # precision 5e-5

##########################################################
#  Reference data Yambo 3.2.1 r 514                      #
#  compiled with gfortran 4.3.3  (-O3 -mtune=native)     #
#  and ABINIT 5.3.4                                      #
##########################################################

G_lesser[1]=0.001272533
G_lesser[2]=0.006297965
G_lesser[3]=0.0
G_lesser[4]=0.03717064
G_lesser[5]=0.0
G_lesser[6]=0.0
G_lesser[7]=0.0
G_lesser[8]=0.0
G_lesser[9]=0.0
G_lesser[10]=0.0
G_lesser[11]=-0.01192654
G_lesser[12]=-0.00009648476
G_lesser[13]=-0.03717065
G_lesser[14]=0.0
G_lesser[15]=-0.046911
G_lesser[16]=0.001404701
G_lesser[17]=0.0007136706
G_lesser[18]=0.007625236
G_lesser[19]=1.99699
G_lesser[20]=-0.04201132
G_lesser[21]=0.0
G_lesser[22]=0.0
G_lesser[23]=0.0
G_lesser[24]=0.0
G_lesser[25]=0.0
G_lesser[26]=0.0
G_lesser[27]=-0.01932921
G_lesser[28]=0.0007506915
G_lesser[29]=-0.04201131
G_lesser[30]=0.001624319
G_lesser[31]=0.01220676
G_lesser[32]=0.0006150323
  
##########################################################

############## YAMBO EXECUTABLE #################
YAMBOPATH="../../../bin/"
YAMBO_RT="${YAMBOPATH}/yambo_rt"
YPP_RT="${YAMBOPATH}/ypp_rt"
A2Y="${YAMBOPATH}/a2y"
#################################################

# check whether echo has the -e option
if test "`echo -e`" = "-e" ; then ECHO=echo ; else ECHO="echo -e" ; fi

# run from directory where this script is
cd `echo $0 | sed 's/\(.*\)\/.*/\1/'` # extract pathname
TEST_DIR=`pwd`

if [ -d test_RT ] ; then
  $ECHO " WARNING: directory test_RT already exists "
  $ECHO ""
fi

rm -rf test_RT
mkdir  test_RT
cd test_RT

$ECHO 
$ECHO " * * * * * * * * * * * * * * * * *"
$ECHO " *        Test RT                *"
$ECHO " * * * * * * * * * * * * * * * * *"
$ECHO 

if [ `which abinis | wc -c` -eq 0 ] ; then
  $ECHO " ABINIT is not in your path!"
  exit 1;
fi

if [ `which ncdump | wc -c` -eq 0 ] ; then
  $ECHO " NCDUMP is not in your path!"
  exit 1;
fi

if [ ! -f $A2Y ] ; then
  $ECHO " Compile yambo interfaces before tests "
  exit 1;
fi

if [ ! -f $YAMBO_RT ] ; then
  $ECHO " Yambo_sc executable not found "
  exit 1;
fi

if [ ! -f $YPP_RT ] ; then
  $ECHO " Ypp_rt executable not found "
  exit 1;
fi

$ECHO " Downloading pseudopotentials...... "
if (! wget ftp://ftp.abinit.org/pub/abinitio/Psps/LDA_TM.psps/05/5b.pspnc &> /dev/null) || ( ! wget ftp://ftp.abinit.org/pub/abinitio/Psps/LDA_TM.psps/07/7n.pspnc &> /dev/null ) then
$ECHO " Error downloading pseudo-potentials "
exit 1;
fi

cat > bn_dft.in << EOF
ndtset 2

nstep 100
kptopt  1        # Option for the automatic generation of k points
nshiftk 1
shiftk  0 0 0
ngkpt1 6 6 1
enunit 1
prteig 1

prtvol1 3
toldfe1 1.0d-9
prtden1 1

symmorphi2 0
iscf2    -2
kptopt2  1        # Option for the automatic generation of k points
nband2  8
nbandkss2 -1
kssform2 3
tolwfr2  1.0d-9
ngkpt2 2 2 1
istwfk2 2*1
getden2 -1

#Definition of the planewave basis set
ecut   25.0        # Minimal kinetic energy cut-off, in Hartree

acell    4.7177372151  4.7177372151 10.0
rprim    1.00000000000000   0.000000000000000   0.00000000000000
        -0.50000000000000   0.866025403784439   0.00000000000000
         0.00000000000000   0.000000000000000   1.00000000000000

ntypat  2
znucl   5 7 
natom   2
typat   1 2 
xcart
  2.3588686075E+00  1.3618934255E+00  0.0000000000E+00
 -2.3588686075E+00 -1.3618934255E+00  0.0000000000E+00
EOF

cat > bn.files << EOF
bn_dft.in
bn_dft.out
bn_dfti
bn_dfto
bn_dft
5b.pspnc
7n.pspnc
EOF

$ECHO " Running ABINIT calculation..... "

if (! abinis < bn.files > output_abinit ) then
$ECHO " Error running ABINIT "
exit 1;
fi

$ECHO " Import WF ..... "

if (! $A2Y -N -S -F bn_dfto_DS2_KSS &> output_a2y) then
$ECHO " Error running A2Y "
exit 1;
fi

$ECHO " Yambo Setup ..... "

cat > yambo_setup.in << EOF
setup                        # [R INI] Initialization
EOF

if (! ${YAMBO_RT} -N -F yambo_setup.in  &> output_setup) then
$ECHO " Error in YAMBO setup "
exit 1;
fi

cat > ypp_fix_symm.in << EOF
rsymm                        # [R] Reduce Symmetries
% EField1
 0.000    | 1.000    | 0.000    |      # First external Electric Field
%
% EField1
 0.000    | 0.000    | 0.000    |      # Additional external Electric Field
%
BField= 000.0000       T     # [MAG] Magnetic field modulus
Bpsi= 0.000000         deg   # [MAG] Magnetic field psi angle [degree]
Btheta= 0.000000       deg   # [MAG] Magnetic field theta angle [degree]
#RmAllSymm                   # Remove all symmetries
EOF

$ECHO " Ypp Fix_symm ..... "

if (! ${YPP_RT} -N -F ypp_fix_symm.in  &> output_setup) then
$ECHO " Error in Ypp_rt fix symmetries "
exit 1;
fi

$ECHO " Yambo Setup 2 ..... "

if (! ${YAMBO_RT} -N -F yambo_setup.in  &> output_setup) then
$ECHO " Error in YAMBO setup2 "
exit 1;
fi

cat > yambo_rt.in << EOF
scpot                        # [R] Self-Consistent potentials
HF_and_locXC                 # [R XX] Hartree-Fock Self-energy and Vxc
negf                         # [R] Real-Time dynamics
rhoIO                        # [R] Extended oscillators IO
EXXRLvcs= 300         RL    # [XX] Exchange RL components
SCBands=  8                  # [SC] Bands
Potential= "HARTREE-FOCK"    # [SC] SC Potential
BandMix= 100.0000            # [SC] Band mixing
Integrator= "RK2"            # [RT] Integrator (RK2 | EULER | EXACT | RK2EXACT)
RTstep=   0.0020       fs    # [RT] Real Time step length
NEsteps= 200                # [RT] Non-equilibrium Time steps
ThermSteps=0                 # [RT] Thermal Steps
Probe_Freq= 0.000000   eV    # [RT Probe] External Field Frequency
Probe_Int= 1.000000    kWLm2 # [RT Probe] External Field Intensity
Probe_kind= "DELTA"           # [RT Probe] External Field (SINUSOIDAL|RESONANT|DELTA|STEP)
% Probe_Dir
 0.000000 | 1.000000 | 0.000000 |      # [RT Probe] Electric Field Versor
%
Probe_Tstart= 0.000000 fs    # [RT Probe] Initial Time
EOF

$ECHO " Yambo RT ..... "

if (! ${YAMBO_RT} -N -F yambo_rt.in  &> output_rt) then
$ECHO " Error in YAMBO RT "
exit 1;
fi

ncdump SAVE/ndb.rtG > data_ndb.rtG
head_lines=`grep -n G_lesser_K2_SPIN1 data_ndb.rtG | tail -1 | awk -F: ' { print $1 }'`

test_ok=1  

for i in `seq 1 32`
do 
  line=`python -c "print ${head_lines} + ${i}"`
  G_disk=`head -${line} data_ndb.rtG | tail -1 | awk -F, '{ print $2 }'` 
  diffG=`python -c "print \"%16.12f\" % abs(${G_disk}-${G_lesser[i]})"`
    if [ $(echo "$diffG < $EPS"|bc -l) -eq 0 ] ; then
       $ECHO " Wrong G_lesser for kpt 2"
       test_ok=0
    fi
done

if [ "$test_ok" -eq 1 ] ; then
   $ECHO " Test RT ==>> OK "
else
   $ECHO " Test RT ==>> failed "
fi                             
