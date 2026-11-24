#!/usr/bin/env bash
#
# ======================= CCTMv6.X Build Script =========================
# Usage: bldit_cctm.sh <compiler> [<version>] &> bldit.cctm.log
# Requirements: I/O API & netCDF libraries, a Fortran compiler,
#               and MPI for multiprocessor computing
#
# To report problems or request help with this script/program:
#             http://www.cmascenter.org
# =======================================================================
set -euo pipefail

#> Manual set-up
 export compiler=gcc
 export Vrsn=15.2
 echo "Compiler is set to $compiler"

#> Source the config file to set the build environment
#  (config_cmaq.sh is the Bash port of config_cmaq.csh)
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${script_dir}/../.."

set +u                      # the config file may reference unset variables
source ./config_cmaq.sh
set -u

#> Variables the config file must provide
for v in CMAQ_HOME CMAQ_REPO CMAQ_LIB compilerString \
         myFC myCC myFSTD myDBG myFFLAGS myFRFLAGS myCFLAGS myLINK_FLAG \
         ioapi_lib netcdf_lib netcdff_lib extra_lib; do
    if [[ -z ${!v+x} ]]; then
        echo "*** ${v} is not set by config_cmaq.sh" >&2
        exit 1
    fi
done
# bldit_bldmake.sh and bldit_mech.* read these from the environment
export compilerString CMAQ_HOME CMAQ_REPO myFC myFFLAGS

set -x                      # csh: "set echo"

# =======================================================================
#> Begin User Input Section
# =======================================================================

#> Source Code Locations
export CCTM_SRC="${CMAQ_REPO}/CCTM/src"   #> location of the CCTM source code
GlobInc="${CCTM_SRC}/ICL"                 #> location of the global include files
Mechs="${CCTM_SRC}/MECHS"                 #> location of the chemistry mechanism include files
export REPOROOT="${CCTM_SRC}"

#> Controls for managing the source code and MPI compilation.
#> Each toggle is "true" or "false".
CompileBLDMAKE=true        #> recompile the BLDMAKE utility from source;
                           #>   false to use an existing BLDMAKE executable
CopySrc=true               #> copy the source files into the build directory
CopySrcTree=false          #> copy the source files and directory tree into the build directory
MakeFileOnly=false         #> true: build a Makefile, but do not compile the model
build_mech=false           #> true: build mechanism source code files using the chemmech utility

#> chemmech options for revising the mechanism definitions file (see
#> UTIL/chemmech/README.md). Uncomment to use.
#>    Rewrite reactions by appending them with changes in tracked atoms or elements
#export COMPUTE_DELTA_ATOMS=F
#>    The species namelist contains the composition information as comments at the end
#>    of lines defining species. If NAMELISTS_LIST_ATOMS equals F, an additional ASCII
#>    file contains the information.
#export NAMELISTS_LIST_ATOMS=T

clobber_mech=false         #> false: bldit_mech halts if newly created mechanism files would
                           #>   replace existing ones; true: overwrite them
ParOpt=true                #> true: multiple processor (MPI) executable; false: serial
DistrEnv=false             #> true: distribute environment variables to multiple machines (MPI only)
build_parallel_io=false    #> true: build with parallel I/O (pnetcdf); false: standard netCDF I/O
Debug_CCTM=false           #> true: compile CCTM with debug option equal to TRUE
make_options="-j"          #> additional options for make if MakeFileOnly is not true;
                           #>   comment out if no additional options are wanted

#> Integrated Source Apportionment Method (ISAM)
ISAM_CCTM=false            #> true: compile CCTM with ISAM activated
DDM3D_CCTM=false           #> true: compile CCTM with DDM-3D activated

#> WRF-CMAQ / MPAS-CMAQ coupled models
build_wrf_cmaq=false       #> true: build WRF-CMAQ coupled model; false: off-line chemistry
build_mpas_cmaq=false      #> true: build MPAS-CMAQ coupled model

#> Working directory and Version IDs
if enabled ISAM_CCTM; then
    VRSN=v6_ISAM           #> model configuration ID for CMAQ_ISAM
elif enabled DDM3D_CCTM; then
    VRSN=v6_DDM3D          #> model configuration ID for CMAQ_DDM
else
    VRSN=v6                #> model configuration ID for CMAQ
fi

EXEC="CCTM_${VRSN}.exe"    #> executable name
CFG="CCTM_${VRSN}.cfg"     #> configuration file name

if enabled build_wrf_cmaq && enabled build_mpas_cmaq; then
    echo " options build_wrf_cmaq and build_mpas_cmaq cannot be used at the same time" >&2
    exit 1
fi

if enabled build_wrf_cmaq; then
    WRF_VRSN=v4.4.1        # WRF version used for WRF-CMAQ Model (must be v4.4+)
fi

#========================================================================
#> CCTM Science Modules
#========================================================================
#> NOTE: For the modules with multiple options, a note is provided on where
#>   to look in the CCTM source code archive for a list of the possible
#>   settings. Users may also refer to the CMAQ documentation.

ModGrid=grid/cartesian         #> grid configuration module

ModAdv=wrf_cons                #> 3-D Advection Scheme [Options: wrf_cons (default), local_cons]
ModHdiff=hdiff/multiscale      #> horizontal diffusion module
ModVdiff=vdiff/acm2            #> vertical diffusion module (see $CMAQ_MODEL/CCTM/src/vdiff)
ModDepv=depv/depv              #> deposition velocity calculation module
                               #>     (see $CMAQ_MODEL/CCTM/src/depv)
ModEmis=emis/emis              #> in-line emissions module
ModBiog=biog/beis4             #> BEIS4 in-line emissions module

ModMegBiog=biog/megan3         #> MEGAN3 in-line emissions module

ModPlmrs=plrise/smoke          #> in-line emissions plume rise
ModCgrds=spcs/cgrid_spcs_nml   #> chemistry species configuration module
                               #>     (see $CMAQ_MODEL/CCTM/src/spcs)
ModPhot=phot/inline            #> photolysis calculation module
                               #>     (see $CMAQ_MODEL/CCTM/src/phot)

export Mechanism=cracmm3       #> chemical mechanism (see $CMAQ_MODEL/CCTM/src/MECHS)
ModMech="MECHS/${Mechanism}"

case "${Mechanism}" in
    *ae7*)                     #> ae7 family of aero and cloud chem
        ModAero=aero/aero7         #> aerosol chemistry module (see $CMAQ_MODEL/CCTM/src/aero)
        ModCloud=cloud/acm_ae7     #> cloud chemistry module (see $CMAQ_MODEL/CCTM/src/cloud)
        ;;
    *ae6*)                     #> ae6 family of aero and cloud chem
        ModAero=aero/aero6
        ModCloud=cloud/acm_ae6
        ;;
    *cracmm*)                  #> CRACMM family of aero and cloud chem
        ModAero=aero/cracmm
        ModCloud=cloud/acm_cracmm
        ;;
    *)
        echo "*** no aerosol/cloud modules defined for mechanism ${Mechanism}" >&2
        exit 1
        ;;
esac

# Special cloud modules for kmt versions
if [[ ${Mechanism} == cb6r5_ae7_aqkmt2 ]]; then
    ModCloud=cloud/acm_ae7_kmt2
fi

# Gas chem solver
export ChemSolver=ebi          #> [ default for most mechanisms: ebi ]
if ! enabled ISAM_CCTM; then   # check whether best solver is best for mechanism
    if [[ ${Mechanism} == cb6r5m_ae7_aq || ${Mechanism} == cracmm3m ]]; then
        #> Gas-phase chemistry solver options ($CMAQ_MODEL/CCTM/src/gas)
        ChemSolver=ros3        #> ros3 (or smvgear) are system independent
    fi
fi

if [[ ${ChemSolver} == ebi ]]; then
    ModGas="gas/${ChemSolver}_${Mechanism}"
else
    ModGas="gas/${ChemSolver}"
fi

ModUtil=util/util              #> CCTM utility modules
ModDiag=diag                   #> CCTM diagnostic modules
Tracer=trac0                   #> tracer configuration directory under
                               #>   $CMAQ_MODEL/CCTM/src/MECHS [ default: no tracer species ]
ModPa=procan/pa                #> CCTM process analysis
ModPvO3=pv_o3                  #> potential vorticity from the free troposphere
ModISAM=isam                   #> CCTM Integrated Source Apportionment Method
ModDDM3D=ddm3d                 #> Decoupled Direct Method in 3D
ModDegrade=reactive_tracers    #> Linear chemical loss for a fixed set of reactive tracers

#============================================================================================
#> Computing System Configuration:
#>    Most of these settings are done in config_cmaq.sh
#============================================================================================

export FC="${myFC}"            #> path of Fortran compiler; set in config
FP="${FC}"                     #> path of Fortran preprocessor; set in config
CC="${myCC}"                   #> path of C compiler; set in config
export BLDER="${CMAQ_HOME}/UTIL/bldmake/bldmake_${compilerString}.exe"  #> model builder executable

#> Libraries/include files
NETCDF="${NETCDF_DIR:-}/lib ${netcdf_lib}"      #> netCDF C library directory
NETCDFF="${NETCDFF_DIR:-}/lib ${netcdff_lib}"   #> netCDF Fortran library directory
PNETCDF="${PNETCDF_DIR:-}/lib ${pnetcdf_lib:-}" #> Parallel netCDF library directory

#> Compiler flags set in config
FSTD="${myFSTD}"
DBG="${myDBG}"
export F_FLAGS="${myFFLAGS}"   #> F77 flags
F90_FLAGS="${myFRFLAGS}"       #> F90 flags
CPP_FLAGS=""                   #> Fortran preprocessor flags
C_FLAGS="${myCFLAGS} -DFLDMN -I"  #> C flags
LINK_FLAGS="${myLINK_FLAG}"    #> Link flags

#============================================================================================
#> Implement User Input
#============================================================================================

#> Check for CMAQ_REPO and CMAQ_LIB settings:
if [[ ! -e ${CMAQ_REPO} || ! -e ${CMAQ_LIB} ]]; then
    echo "   ${CMAQ_REPO} or ${CMAQ_LIB} directory not found" >&2
    exit 1
fi
echo "    Model repository base path: ${CMAQ_REPO}"
echo "                  library path: ${CMAQ_LIB}"

#> If CMAQ_MODEL is not set, default to CMAQ_REPO
if [[ -n ${CMAQ_MODEL+x} ]]; then
    echo "         Model repository path: ${CMAQ_MODEL}"
else
    export CMAQ_MODEL="${CMAQ_REPO}"
    echo " default Model repository path: ${CMAQ_MODEL}"
fi

#> This script was written for Linux hosts only. If
#> the host system is not Linux, produce an error and stop
BLD_OS=$(uname -s)
if [[ ${BLD_OS} != Linux ]]; then
    echo "   ${BLD_OS} -> wrong bldit script for host!" >&2
    exit 1
fi

#> If the WRF-CMAQ coupled model is being built,
#> then just generate the Makefile. Don't compile.
if enabled build_wrf_cmaq; then
    MakeFileOnly=true
    Modwrfcmaq=twoway
    Modcoupler=unified_coupler
fi

#> If the MPAS-CMAQ coupled model is being built,
#> then just generate the Makefile. Don't compile.
if enabled build_mpas_cmaq; then
    MakeFileOnly=true
    Modmpascmaq=mpas_cmaq
    ModMio=mio
fi

#> If parallel-io is selected, then make sure the multiprocessor
#> option is also set.
PIO=()
if enabled build_parallel_io; then
    if ! enabled ParOpt; then
        echo "*** ParOpt is not set: required for the build_parallel_io option" >&2
        exit 1
    fi
    PIO=(-Dparallel_io)
fi

#> Set variables needed for multiprocessor and serial builds
PAR=()
if enabled ParOpt; then
    # Multiprocessor system configuration
    echo "   Parallel; set MPI flags"
    : "${mpi_lib:?mpi_lib must be set by config_cmaq.sh for a parallel build}"
    ModStenex=STENEX/se
    ModPario=PARIO
    ModPar=par/mpi
    PARIO="${CMAQ_MODEL}/PARIO"
    STENEX="${CMAQ_MODEL}/STENEX"
    # MPI_INC is set in config
    PAR=(-Dparallel)
    Popt=SE
    seL=se_snl
    LIB2="${ioapi_lib}"
    LIB3="${mpi_lib} ${extra_lib}"
    # Distribute environment to different machines if not done automatically
    if enabled DistrEnv; then
        PAR+=(-Dcluster)
    fi
else
    # Serial system configuration
    echo "   Not Parallel; set Serial (no-op) flags"
    ModStenex=STENEX/noop
    ModPar=par/par_noop
    PARIO="."
    STENEX="${CMAQ_MODEL}/STENEX/noop"
    MPI_INC="."
    Popt=NOOP
    seL=sef90_noop
    LIB2="${ioapi_lib} ${extra_lib}"
fi

#> if DDM-3D is set, add the pre-processor flag for it.
SENS=()
if enabled DDM3D_CCTM; then
    SENS=(-Dsens)
fi

#> Build Mechanism Files and instruct build-make to look
#> in the CHEMMECH output folder for the files
if enabled build_mech; then

    # Note: modifying existing or creating new chemical mechanisms
    # can lead to unstable or highly inaccurate representations of
    # atmospheric chemical predictions when applying the EBI solvers.
    # EBI solvers are highly characterized and tested before
    # application. The CMAQ development team recommends using the
    # generalized solvers, Rosenbrock or Gear, with user-defined
    # mechanisms.

    # Because the bldit_cctm script is executing the bldit_mech
    # processor, we will assume that the source location for the new
    # mechanism files is in the CMAQ repo. There is also an
    # error check for overwriting an existing mechanism that can be
    # disabled using the clobber_mech toggle above.
    export MECH_SRC="${CMAQ_REPO}/CCTM/src/${ModMech}"
    export TRAC_NML="${CMAQ_REPO}/CCTM/src/MECHS/trac0/Species_Table_TR_0.nml"
    export MECH_OUT="${CMAQ_REPO}/CCTM/src/${ModMech}"
    export EBI_SOLVER_OUT="${CMAQ_REPO}/CCTM/src/${ModGas}"
    if enabled clobber_mech; then
        export CLOBBER_MECH=TRUE
    else
        export CLOBBER_MECH=FALSE
    fi

    cd "${CMAQ_HOME}/CCTM/scripts"
    if ! ./bldit_mech.csh "${compiler}" "${compilerVrsn}"; then
        echo "" >&2
        echo "bldit_mech did not finish correctly --> Build Process Halted" >&2
        exit 1
    fi
fi

#> Tracer configuration files
ModTrac="MECHS/${Tracer}"

#> Set and create the "BLD" directory for checking out and compiling
#> source code. Move current directory to that build directory.
if enabled Debug_CCTM; then
    Bld="${CMAQ_HOME}/CCTM/scripts/BLD_CCTM_${VRSN}_${compilerString}_debug_${Mechanism}"
else
    Bld="${CMAQ_HOME}/CCTM/scripts/BLD_CCTM_${VRSN}_${compilerString}_${Mechanism}"
fi

if [[ ! -e ${Bld} ]]; then
    mkdir -p "${Bld}"
elif [[ ! -d ${Bld} ]]; then
    echo "   *** target exists, but not a directory ***" >&2
    exit 1
fi
cd "${Bld}"

#> Set locations for the include files of various modules
ICL_PAR="${GlobInc}/fixed/mpi"
ICL_CONST="${GlobInc}/fixed/const"
ICL_FILES="${GlobInc}/fixed/filenames"
ICL_EMCTL="${GlobInc}/fixed/emctrl"

if enabled ParOpt; then
    ICL_MPI="."
fi

#> If the source code is being copied to the build directory,
#> then move the include files as well and direct the Makefile
#> to the current directory.
if enabled CopySrc; then
    cp -fp "${ICL_PAR}"/*   "${Bld}"
    cp -fp "${ICL_CONST}"/* "${Bld}"
    cp -fp "${ICL_FILES}"/* "${Bld}"
    cp -fp "${ICL_EMCTL}"/* "${Bld}"
    if enabled ParOpt; then
        # ICL_MPI is "." (the build dir), so skip the copy when it would be a no-op or
        # the file is missing (under set -e either case would abort the script)
        if [[ -f ${ICL_MPI}/mpif.h && ! ${ICL_MPI}/mpif.h -ef ${Bld}/mpif.h ]]; then
            cp -fp "${ICL_MPI}/mpif.h" "${Bld}"
        fi
    fi

    ICL_PAR="."
    ICL_CONST="."
    ICL_FILES="."
    ICL_EMCTL="."
    if enabled ParOpt; then
        ICL_MPI="."
    fi
fi

STX1=(
    "-DSUBST_BARRIER=${Popt}_BARRIER"
    "-DSUBST_GLOBAL_MAX=${Popt}_GLOBAL_MAX"
    "-DSUBST_GLOBAL_MIN=${Popt}_GLOBAL_MIN"
    "-DSUBST_GLOBAL_MIN_DATA=${Popt}_GLOBAL_MIN_DATA"
    "-DSUBST_GLOBAL_TO_LOCAL_COORD=${Popt}_GLOBAL_TO_LOCAL_COORD"
    "-DSUBST_GLOBAL_SUM=${Popt}_GLOBAL_SUM"
    "-DSUBST_GLOBAL_LOGICAL=${Popt}_GLOBAL_LOGICAL"
    "-DSUBST_GLOBAL_GATHER=${Popt}_GLOBAL_GATHER"
    "-DSUBST_GLOBAL_BCAST=${Popt}_GLOBAL_BCAST"
    "-DSUBST_LOOP_INDEX=${Popt}_LOOP_INDEX"
    "-DSUBST_SUBGRID_INDEX=${Popt}_SUBGRID_INDEX"
)
STX2=(
    "-DSUBST_HI_LO_BND_PE=${Popt}_HI_LO_BND_PE"
    "-DSUBST_SUM_CHK=${Popt}_SUM_CHK"
    "-DSUBST_SE_INIT=${Popt}_INIT"
    "-DSUBST_INIT_ARRAY=${Popt}_INIT_ARRAY"
    "-DSUBST_COMM=${Popt}_COMM"
    "-DSUBST_MY_REGION=${Popt}_MY_REGION"
    "-DSUBST_SLICE=${Popt}_SLICE"
    "-DSUBST_GATHER=${Popt}_GATHER"
    "-DSUBST_DATA_COPY=${Popt}_DATA_COPY"
    "-DSUBST_IN_SYN=${Popt}_IN_SYN"
)

#> 3-D Advection Options
case "${ModAdv}" in
    wrf_cons)
        ModCpl=couple/gencoor_wrf_cons     #> unit conversion and concentration coupling module
                                           #>     (see $CMAQ_MODEL/CCTM/src/couple)
        ModHadv=hadv/ppm                   #> horizontal advection module
        ModVadv=vadv/wrf_cons              #> vertical advection module
        ;;
    local_cons)
        ModCpl=couple/gencoor_local_cons
        ModHadv=hadv/ppm
        ModVadv=vadv/local_cons
        ;;
    *)
        echo "*** unsupported advection scheme: ${ModAdv}" >&2
        exit 1
        ;;
esac

# Retrieve git repository sha ID for this source code version
if ! shaID=$(git --git-dir="${CMAQ_REPO}/.git" rev-parse --short=10 HEAD 2>/dev/null); then
    shaID="not_a_repo"
fi

# ============================================================================
#> Create Config File
# ============================================================================

Cfile="${Bld}/${CFG}.bld"      # Config filename
q='"'

field()      { printf '%s\n\n' "$*"; }                                   # line + blank line
cfg_module() { printf '// options are %s\nModule %s;\n\n' "$1" "$2"; }   # $1 = options, $2 = module

MechList="cb6r5_ae7_aq, cb6r5_ae7_aqkmt2, cb6r5hap_ae7_aq, cb6r5m_ae7_aq, cracmm2, cracmm3, saprc07tc_ae6_aq, saprc07tic_ae7i_aq"

if enabled build_mpas_cmaq; then
    cpp_text="${CPP_FLAGS} ${PAR[*]} ${SENS[*]} ${PIO[*]}"
else
    cpp_text="${CPP_FLAGS} ${PAR[*]} ${SENS[*]} ${PIO[*]} ${STX1[*]} ${STX2[*]}"
fi

{
    echo
    if [[ -n ${make_options+x} ]]; then
        field "make_options ${q}${make_options}${q};"
    fi
    field "model        ${EXEC};"
    field "repo        ${CCTM_SRC};"
    field "sha_ID      ${shaID};"
    field "mechanism   ${Mechanism};"
    field "lib_base    ${CMAQ_LIB};"
    field "lib_1       ioapi/lib;"
    field "lib_2       ioapi/include_files;"
    if enabled ParOpt; then
        field "lib_3       ${q}mpi -I.${q};"
    fi
    field "lib_4       ioapi/lib;"
    field "cpp_flags   ${q}${cpp_text}${q};"
    field "f_compiler  ${FC};"
    field "fstd        ${q}${FSTD}${q};"
    field "dbg         ${q}${DBG}${q};"
    field "f_flags     ${q}${F_FLAGS}${q};"
    field "f90_flags   ${q}${F90_FLAGS}${q};"
    field "c_compiler  ${CC};"
    field "c_flags     ${q}${C_FLAGS}${q};"
    field "link_flags  ${q}${LINK_FLAGS}${q};"
    field "ioapi       ${q}${LIB2}${q};"
    field "netcdf      ${q}${netcdf_lib}${q};"
    field "netcdff     ${q}${netcdff_lib}${q};"
    if enabled ParOpt; then
        field "mpich       ${q}${LIB3}${q};"
    fi
    echo "include SUBST_PE_COMM    ${ICL_PAR}/PE_COMM.EXT;"
    echo "include SUBST_FILES_ID   ${ICL_FILES}/FILES_CTM.EXT;"
    echo "include SUBST_EMISPRM    ${ICL_EMCTL}/EMISPRM.EXT;"
    echo
    echo

    echo "// options are stenex or se_noop"
    echo "Module ${ModStenex};"
    if enabled ParOpt; then
        echo "// parallel executable; stenex and pario included"
        echo "Module ${ModPario};"
    else
        echo "serial executable; noop stenex"   # (no leading // in the original either)
    fi
    echo

    echo "// options are par, par_nodistr and par_noop"
    if enabled ParOpt; then
        echo "Module ${ModPar};"
    fi
    echo

    if enabled build_wrf_cmaq; then
        echo "// option set for WRF-CMAQ coupled model"
        echo "Module ${Modwrfcmaq};"
        echo "Module ${Modcoupler};"
        echo
    fi

    if enabled build_mpas_cmaq; then
        echo "// option set for MPAS-CMAQ coupled model"
        echo "Module ${Modmpascmaq};"
        echo
    fi

    cfg_module "driver"  "driver"
    cfg_module "cartesian" "${ModGrid}"
    cfg_module "Init"    "init"
    cfg_module "gencoor_wrf_cons and gencoor_local_cons" "${ModCpl}"
    cfg_module "ppm"     "${ModHadv}"
    cfg_module "wrf_cons and local_cons" "${ModVadv}"
    cfg_module "multiscale" "${ModHdiff}"
    cfg_module "acm2_m3dry or acm2_stage" "${ModVdiff}"
    cfg_module "m3dry or stage" "${ModDepv}"
    cfg_module "emis"    "${ModEmis}"
    cfg_module "beis4"   "${ModBiog}"
    cfg_module "megan3"  "${ModMegBiog}"

    if enabled build_mpas_cmaq; then
        cfg_module "mio" "${ModMio}"
    fi

    cfg_module "smoke"   "${ModPlmrs}"
    cfg_module "cgrid_spcs_nml and cgrid_spcs_icl" "${ModCgrds}"
    cfg_module "inline and table" "${ModPhot}"

    echo "// reactive_tracer options are degrade"
    echo "Module ${ModDegrade};"
    echo

    echo "// gas chemistry solvers"
    cfg_module "smvgear, ros3, and ebi; see 'gas chemistry mechanisms' for <mech>" "${ModGas}"

    echo "// gas chemistry mechanisms"
    cfg_module "${MechList}" "${ModMech}"

    echo "// tracer modules"
    echo "// options are trac0, trac1"
    echo "Module ${ModTrac};"
    echo

    cfg_module "use potential vorticity free-troposphere O3 scaling" "${ModPvO3}"
    cfg_module "aero6" "${ModAero}"
    cfg_module "acm_ae6, acm_ae7_kmt2" "${ModCloud}"

    echo "// compile for inline process analysis"
    echo "Module ${ModPa};"
    echo

    echo "// compile for integrated source apportionment method"
    echo "Module ${ModISAM};"
    echo

    if enabled DDM3D_CCTM; then
        echo "// compile for decoupled direct method in 3d"
        echo "Module ${ModDDM3D};"
        echo
    fi

    cfg_module "util" "${ModUtil}"
    cfg_module "diag" "${ModDiag}"
    cfg_module "stm"  "stm"
    cfg_module "cio"  "cio"

    if [[ -n ${ModMisc+x} ]]; then
        echo "Module ${ModMisc};"
        echo
    fi
} > "${Cfile}"

# ============================================================================
#> Create Makefile and Model Executable
# ============================================================================

#> Recompile BLDMAKE from source if requested or if it does not exist
if enabled CompileBLDMAKE || [[ ! -f ${BLDER} ]]; then
    (
        cd "${CMAQ_REPO}/UTIL/bldmake/scripts"
        # bldit_bldmake.sh treats CompileBLDMAKE as "set => recompile"
        if enabled CompileBLDMAKE; then
            export CompileBLDMAKE=1
        else
            unset CompileBLDMAKE
        fi
        ./bldit_bldmake.sh
    )
fi

#> Relocate to the BLD_* directory
cd "${Bld}"

#> Set multiprocessor/serial options for BLDMAKE execution
if enabled ParOpt; then
    Blder=("${BLDER}" -verbose)
else
    Blder=("${BLDER}" -serial -verbose)
fi

#> Assemble BLDMAKE flags
bld_flags=()
if enabled MakeFileOnly; then   # do not compile the model
    bld_flags+=(-makefo)
fi

if enabled CopySrc; then
    :                           # source is copied into the build directory
elif enabled CopySrcTree; then
    bld_flags+=(-co)
else
    bld_flags+=(-git_local)     # run BLDMAKE with source in the version-controlled git repo
fi

if enabled Debug_CCTM;      then bld_flags+=(-debug_cctm); fi
if enabled ISAM_CCTM;       then bld_flags+=(-isam_cctm);  fi
if enabled build_wrf_cmaq;  then bld_flags+=(-twoway);     fi
if enabled build_mpas_cmaq; then bld_flags+=(-mpascmaq);   fi

#> Run BLDMAKE (config file: ${Cfile} = ${CFG}.bld); stop right away if it fails
if ! "${Blder[@]}" "${bld_flags[@]}" "${Cfile}"; then
    echo "   *** failure in ${Blder[*]} ***" >&2
    exit 1
fi

#> Rename Makefile to specify compiler option and link back to Makefile
if enabled build_mpas_cmaq; then
    ln -sf Makefile.mpas_cmaq Makefile
elif ! enabled build_wrf_cmaq; then
    mv Makefile "Makefile.${compilerString}"
    if [[ -e Makefile.${compilerString} ]]; then
        rm -f Makefile
    fi
    ln -s "Makefile.${compilerString}" Makefile
fi

#> Preserve old Config file, if it exists, before moving new one to
#> build directory.
if [[ -e ${Bld}/${CFG} ]]; then
    echo "   >>> previous ${CFG} exists, re-naming to ${CFG}.old <<<"
    mv "${Bld}/${CFG}" "${Bld}/${CFG}.old"
fi
mv "${CFG}.bld" "${Bld}/${CFG}"

#> gcc compiler chokes on trailing comments in namelists
if [[ ${compiler} == gcc ]]; then
    echo "   >>> removing trailing comments from namelists <<<"
    shopt -s nullglob
    for fnml in "${Bld}"/*.nml; do
        sed -i 's/,!.*/,/' "${fnml}"
    done
    shopt -u nullglob
fi

#> If Building WRF-CMAQ, download WRF, download auxiliary files and build model
if enabled build_wrf_cmaq; then

    #> Check if the user has git installed on their system
    if git --version &> /dev/null; then

        cd "${CMAQ_HOME}/CCTM/scripts"

        # Download WRF repository from GitHub and put CMAQ into it
        WRF_BLD="BLD_WRF${WRF_VRSN}_CCTM_${VRSN}_${compilerString}"
        export wrf_path="${CMAQ_HOME}/CCTM/scripts/${WRF_BLD}"
        export WRF_CMAQ=1

        if [[ ! -d ${WRF_BLD} ]]; then
            : "${WRF_ARCH:?WRF_ARCH (WRF configure option) must be set for build_wrf_cmaq}"
            git clone --branch "${WRF_VRSN}" https://github.com/wrf-model/WRF.git "./${WRF_BLD}" &> /dev/null
            cd "${wrf_path}"
            mv "${Bld}" ./cmaq

            # Configure WRF
            printf '%s\n1\n' "${WRF_ARCH}" | ./configure
        fi

        # Compile WRF-CMAQ
        cd "${wrf_path}"
        ./compile em_real 2>&1 | tee -a wrf-cmaq_buildlog.log

        cd "${CMAQ_HOME}/CCTM/scripts"
    fi
fi

exit 0
