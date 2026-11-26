#!/usr/bin/env bash
#
# ====================== BCONv6.X Build Script ======================
# Usage: bldit_bcon.sh <compiler> [<version>] &> bldit_bcon.log
# Requirements: I/O API & netCDF libs and a Fortran compiler
# Note that this script is configured/tested for Red Hat Linux O/S
#
# To report problems or request help with this script/program:
#             http://www.cmascenter.org
# ===================================================================
set -euo pipefail

# True when the toggle named in $1 is set to "true"
enabled() { [[ "${!1:-}" == true ]]; }

usage() {
    echo "usage: $0 <compiler> [<version>]" >&2
    echo " where <compiler> is intel, pgi or gcc" >&2
}

#> Set Compiler Identity by User Input: Options -> intel | pgi | gcc
case $# in
    1) export compiler=$1 compilerVrsn=Empty ;;
    2) export compiler=$1 compilerVrsn=$2 ;;   # compiler name and version provided
    *) usage; exit 2 ;;
esac

#> Source the config file to set the build environment
#  (config_cmaq.sh is the Bash port of config_cmaq.csh)
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${script_dir}/../../.."

set +u                      # the config file may reference unset variables
source ./config_cmaq.sh
set -u

#> Variables the config file must provide
for v in CMAQ_HOME CMAQ_REPO CMAQ_LIB compilerString \
         myFC myFSTD myDBG myFFLAGS myFRFLAGS myLINK_FLAG \
         ioapi_lib netcdf_lib netcdff_lib extra_lib; do
    if [[ -z ${!v+x} ]]; then
        echo "*** ${v} is not set by config_cmaq.sh" >&2
        exit 1
    fi
done
# bldit_bldmake.sh reads these from the environment
export compilerString CMAQ_HOME CMAQ_REPO myFC myFFLAGS

set -x                      # csh: "set echo"

# =======================================================================
#> Begin User Input Section
# =======================================================================

#> Source Code Locations
BCON_SRC="${CMAQ_REPO}/PREP/bcon/src"   #> location of the BCON source code
export REPOROOT="${BCON_SRC}"

#> Working directory and Version IDs
VRSN=v6                     #> Code Version
EXEC="BCON_${VRSN}.exe"     #> executable name for this application
CFG="BCON_${VRSN}.cfg"      #> BLDMAKE configuration file name

#> Controls for managing the source code and compilation.
#> Each toggle is "true" or "false".
CompileBLDMAKE=true         #> recompile the BLDMAKE utility from source;
                            #>   false to use an existing BLDMAKE executable
CopySrc=true                #> copy the source files into the BLD directory
CopySrcTree=false           #> copy the source files and directory tree into the build directory
                            #>   (not used by the build logic below, as in the original)
Opt=""                      #> "verbose" shows requested commands as they are executed
MakeFileOnly=false          #> true: build a Makefile, but do not compile
Debug_BCON=false            #> true: compile BCON with debug option equal to TRUE

#>==============================================================================
#> BCON Science Modules
#>
#> NOTE:  BC type is now a runtime option.  All BC types are included at
#>        compile time
#>==============================================================================

ModCommon=common
ModM3conc=m3conc
ModProfile=profile

#>#>#>#>#>#>#>#>#>#>#>#>#>#> End User Input Section #<#<#<#<#<#<#<#<#<#<#<#<#<#

#> Set full path of Fortran 90 compiler
FC="${myFC}"
FP="${FC}"
export BLDER="${CMAQ_HOME}/UTIL/bldmake/bldmake_${compilerString}.exe"   #> name of model builder executable

#> Set compiler flags
xLib_Base="${CMAQ_LIB}"
xLib_1=ioapi/lib
xLib_2=ioapi/include_files
xLib_4=ioapi/lib
FSTD="${myFSTD}"
DBG="${myDBG}"
F_FLAGS="${myFFLAGS}"
F90_FLAGS="${myFRFLAGS}"
CPP_FLAGS=""
LINK_FLAGS="${myLINK_FLAG}"

LIB1="${ioapi_lib}"
LIB2="${netcdf_lib} ${extra_lib}"
LIB3="${netcdff_lib}"

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
#  (the pasted csh was missing the rest of this block; restored as in bldit_cctm)
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

#> Set and create the "BLD" directory for checking out and compiling
#> source code. Move current directory to that build directory.
Bld="${CMAQ_HOME}/PREP/bcon/scripts/BLD_BCON_${VRSN}_${compilerString}"
if [[ ! -e ${Bld} ]]; then
    mkdir -p "${Bld}"
elif [[ ! -d ${Bld} ]]; then
    echo "   *** target exists, but not a directory ***" >&2
    exit 1
fi
cd "${Bld}"

#> make the config file
Cfile="${CFG}.bld"
q='"'

field()      { printf '%s\n\n' "$*"; }                                   # line + blank line
cfg_module() { printf '// %s %s\nModule %s;\n\n' "$1" "$2" "$3"; }       # $1 = "options are"/"required", $2 = text, $3 = module

{
    echo
    field "model       ${EXEC};"
    field "repo        ${BCON_SRC};"
    field "lib_base    ${xLib_Base};"
    field "lib_1       ${xLib_1};"
    field "lib_2       ${xLib_2};"
    field "lib_4       ${xLib_4};"
    field "cpp_flags   ${q}${CPP_FLAGS}${q};"
    field "f_compiler  ${FC};"
    field "fstd        ${q}${FSTD}${q};"
    field "dbg         ${q}${DBG}${q};"
    field "f_flags     ${q}${F_FLAGS}${q};"
    field "f90_flags   ${q}${F90_FLAGS}${q};"
    field "link_flags  ${q}${LINK_FLAGS}${q};"
    field "ioapi       ${q}${LIB1}${q};"
    field "netcdf      ${q}${LIB2}${q};"
    field "netcdff      ${q}${LIB3}${q};"

    field "// project repository location: ${BCON_SRC}"

    cfg_module "required"    "common"  "${ModCommon}"
    cfg_module "options are" "m3conc"  "${ModM3conc}"
    cfg_module "options are" "profile" "${ModProfile}"

    if [[ -n ${ModMisc+x} ]]; then
        field "Module ${ModMisc};"
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
Blder=("${BLDER}" -serial -verbose)

#> Relocate to the BLD_* directory
cd "${Bld}"

# Set BCON debug flags if true (the original also passes -debug_cctm here)
if enabled Debug_BCON; then
    Blder+=(-debug_cctm)
fi

#> Assemble and run the BLDMAKE utility
bld_flags=()
if enabled MakeFileOnly; then   # do not compile the model
    bld_flags+=(-makefo)
fi
if ! enabled CopySrc; then
    bld_flags+=(-git_local)     # use source in the version-controlled git repo
fi

#> Alert user of error in BLDMAKE if it occurred (checked right away)
if ! "${Blder[@]}" "${bld_flags[@]}" "${Cfile}"; then
    echo "   *** failure in ${Blder[*]} ***" >&2
    exit 1
fi

#> Rename Makefile to specify compiler option and link back to Makefile
mv Makefile "Makefile.${compilerString}"
if [[ -e Makefile.${compilerString} && -e Makefile ]]; then
    rm -f Makefile
fi
ln -sf "Makefile.${compilerString}" Makefile

#> Preserve old Config file, if it exists, before moving new one to
#> build directory.
if [[ -e ${Bld}/${CFG} ]]; then
    echo "   >>> previous ${CFG} exists, re-naming to ${CFG}.old <<<"
    mv "${Bld}/${CFG}" "${Bld}/${CFG}.old"
fi
mv "${CFG}.bld" "${Bld}/${CFG}"

exit 0
