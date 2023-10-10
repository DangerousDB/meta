#!/bin/false
# This file is only meant to be source'd hence the dummy hashbang
# shellcheck shell=sh
#

addCleanupTrapCmd()
{
  newCmd=$(echo "$1" | sed -e 's/^[ ]*//' -e 's/[ ]*$//')
  if [ -e "${ZOPEN_CLEANUP_PIPE}" ]; then
    (echo "${newCmd}" > "${ZOPEN_CLEANUP_PIPE}")&
  else
    printSoftError "Cleanup pipeline not available; temporary files and resources might not be cleared"
  fi
}

cleanupFunction()
{
  # Only action the cleanup pipeline when not in a sub-zopen-process
  parentname=$(ps -o args= -p "${PPID}" | tr -s ' ' | cut -d' ' -f2  | xargs basename)
  suf="${parentname#zopen}"
  if  [ x"zopen${suf}" = x"${parentname}" ]; then
    # we are a child of a zopen process so do not attempt to cleanuup yet!
    return
  fi
  
  if [ -e "${ZOPEN_CLEANUP_PIPE}" ]; then
    while read cleanupcmd; do
      eval "${cleanupcmd}" 2>/dev/null
    done < "${ZOPEN_CLEANUP_PIPE}"
    rm -rf "${ZOPEN_CLEANUP_PIPE}"
  fi
  trap - EXIT INT TERM QUIT HUP
  
}

# Given two input files, return those lines in haystack file that are 
# not in needles file
diffFile()
{
  haystackfile="$1"
  needlesfile="$2"
  [ -s "${needlesfile}" ] || printError "Internal error; needle file was empty/non-existent."
  diff=$(awk 'NR==FNR{needles[$0];next} 
    !($0 in needles) {print}' "${needlesfile}" "${haystackfile}")
  echo "${diff}"
}

# Given two input lists (with \n delimiters), return those lines in  
# haystack that are not in needles
diffList()
{
  haystack="$1"
  needles="$2"
  haystackfile=$(mktempfile "haystack")
  cat "${haystack}" >"${haystackfile}"
  needlesfile=$(mktempfile "needles")
  cat "${needles}" >"${needlesfile}"
  diffFile "${needlesfile}" "${haystackfile}"
}
# Generate a file name that has a high probability of being unique for
# use as a temporary filename - the filename should be unique in the 
# instance it was generated and probability suggests it should be for
# a "reasonable" time after...
mktempfile()
{
  prefix="zopen_$1"
  suffix=".tmp"
  [ -n "$2" ] && [ ! "$2" = "." ] && suffix="$2"
  for tmp in "${TMPDIR}" "${TMP}" /tmp; do
    [ -n "${tmp}" ] && [ -d "${tmp}" ] && break
  done
  [ ! -d "${tmp}" ] && printError "Could not locate suitable temporary directory [tried \$TMPDIR \$TMP & /tmp]. Define a temporary location and retry command"
  rnd=$(od -vAn -tu8 -N8  < /dev/urandom | tr -d "[:blank:]")
  tempfile="${tmp}/${prefix%%_}_${rnd}.${suffix##.}"
  if [ -e  "${tempfile}" ]; then
    mktempfile "$1" "${suffix}" # recurse and try again
  else
    echo "${tempfile}"
  fi
}

# Create a temporary directory
mktempdir()
{
  tempdir=$(mktempfile "$1")
  [ ! -e "${tempdir}" ] && mkdir "${tempdir}" && addCleanupTrapCmd "rm -rf ${tempdir}" && echo "${tempdir}"
}

isPermString()
{
  test=$(echo "$1" | zossed "s/[-+rwxugo,=]//g")
  if [ -n "${test}" ]; then
    printDebug "Permission string '$1' was invalid"
    false; 
  else
    true;
  fi
  return # the output of the last command
}

writeConfigFile(){
  configFile="$1"
  rootfs="$2"
  pkginstall="$3"
  certPath="$4"

  cat << EOF >  "${configFile}"
# z/OS Open Tools Configuration file
# Main root location for the zopen installation; can be changed if the
# underlying root location is copied/moved elsewhere as locations are
# relative to this envvar value
ZOPEN_ROOTFS=\"${rootfs}\"
export ZOPEN_ROOTFS
configStartTime=\${SECONDS}
zot=\"z/OS Open Tools\"

# Temporary file location
for tmp in "\${TMPDIR}" "\${TMP}" /tmp
do
  if [ ! -z \${tmp} ] && [ -d \${tmp} ]; then
    break
  fi
done

if [ ! -d "\${tmp}" ]; then
  echo "Temporary directory not found. Specify \${TMPDIR}, \${TMP} or have a valid /tmp directory"
fi
FIFO_PIPE_DOTENVS="\${tmp}/zopen_\${LOGNAME}.dotenv.pipe"
FIFO_PIPE_STDOUT="\${tmp}/zopen_\${LOGNAME}.stdout.pipe"

# Set Traps
atExit() {
  sig=\$?
  [ ! -z "\${FIFO_PIPE_DOTENVS}" -a -p \${FIFO_PIPE_DOTENVS} ] && rm -rf \${FIFO_PIPE_DOTENVS}
  [ ! -z "\${FIFO_PIPE_STDOUT}" -a -p \${FIFO_PIPE_STDOUT} ] && rm -rf \${FIFO_PIPE_STDOUT}
  trap - EXIT INT TERM QUIT HUP
  return \${sig}
}

trap "atExit" EXIT INT TERM QUIT HUP

sanitizeEnvVar(){
  # remove any envvar entries that match the specified regex
  value="\$1"
  delim="\$2"
  prefix="\$3"
  echo "\${value}" | awk -v RS="\${delim}" -v DLIM="\${delim}" -v PRFX="\${prefix}" '{ if (match(\$1, PRFX)==0) {printf("%s%s",\$1,DLIM)}}'
}

deleteDuplicateEntries() 
{
  value="\$1"
  delim="\$2"
  echo "\${value}\${delim}" | awk -v RS="\${delim}" '!(\$0 in a) {a[\$0]; printf("%s%s", col, \$0); col=RS; }' | sed "s/\${delim}$//"
}

# z/OS Open Tools environment variables
ZOPEN_PKGINSTALL=\${ZOPEN_ROOTFS}/${pkginstall}
export ZOPEN_PKGINSTALL
ZOPEN_SEARCH_PATH=\${ZOPEN_ROOTFS}/usr/share/zopen/
export ZOPEN_SEARCH_PATH
ZOPEN_CA=\"\${ZOPEN_ROOTFS}/${certPath}\"
export ZOPEN_CA
ZOPEN_LOG_PATH=\${ZOPEN_ROOTFS}/var/log
export ZOPEN_LOG_PATH

# Disable ANSI terminal commands if terminal does not support them
# Currently only OMVS detected
if [ "\${_BPX_TERMPATH-x}" = "OMVS" ];  then
  ansiEnabled=false
else
  ansiEnabled=true
fi

# Custom parameters for zopen default tooling
# Add any custom parameters for curl
ZOPEN_CURL_PARAMS=""

# Environment variables

if [ -z "\${ZOPEN_QUICK_LOAD}" ]; then
  if [ -e "\${ZOPEN_ROOTFS}/etc/profiled" ]; then
    dotenvs=\$(find "\${ZOPEN_ROOTFS}/etc/profiled" -type f -name 'dotenv' -print)
    dotenvcnt=\$(echo "\${dotenvs}" | wc -l | tr -d ' ')
    filecnt=0
    # Create a pipe to hold the list of dotenv dirs to process
    [ ! -p \${FIFO_PIPE_DOTENVS} ] || rm -f \${FIFO_PIPE_DOTENVS}
    mkfifo \${FIFO_PIPE_DOTENVS}
    chtag -tc 819 \${FIFO_PIPE_DOTENVS}
    # Create a pipe to hold any output from the attempt to run the
    # dotenv sourcing to allow errors to propogate to the user
    [ ! -p \${FIFO_PIPE_STDOUT} ] || rm -f \${FIFO_PIPE_STDOUT}
    mkfifo \${FIFO_PIPE_STDOUT}
    chtag -tc 819 \${FIFO_PIPE_STDOUT}
    [ \${ansiEnabled} ] && /bin/echo ""
    (/bin/echo "\${dotenvs}" | xargs | tr ' ' '\n'>>\${FIFO_PIPE_DOTENVS} &)
    while read FILE; do
      [ -z "\${TMP_FIFO_PIPE}" ] && break
      filecnt=\$(expr \${filecnt} + 1)
      pct=\$(expr \${filecnt} \* 100)
      pct=\$(expr \${pct} / \${dotenvcnt})
      if \${ansiEnabled};  then
        /bin/echo "\047[1A\047[\$30D\047[2K- Processing \${zot} configuration: \${pct}% (\${filecnt}/\${dotenvcnt})"
      else
        /bin/echo "Processing \${zot} configuration...: \${pct}% (\${filecnt}/\${dotenvcnt})"
      fi
      [ -e \${FILE} ] && . \${FILE} >\${FIFO_PIPE_STDOUT} 2>&1
      # If there were any messages during the dotenv processing, output to screen
      while read outputline; do
        if [ -n "\${outputline}" ]; then
          if \${ansiEnabled}; then
            inserSpacer=true
          fi
          printf "%szn" "\${outputline}"
        fi
      done < \${FIFO_PIPE_STDOUT}
      [ \${insertSpacer} ] || printf "\n\n" # Add blank lines to restart the spinner otherwise messages from setup are overwritten
    done < \${FIFO_PIPE_DOTENVS}
    [ -n "\${FIFO_PIPE_DOTENVS}" -a -e "\${FIFO_PIPE_DOTENVS}" ] || rm -f "\${FIFO_PIPE_DOTENVS}"
    [ -n "\${FIFO_PIPE_STDOUT}" -a -e "\${FIFO_PIPE_STDOUT}" ] || rm -f "\${FIFO_PIPE_STDOUT}"
    if \${ansiEnabled};  then
      /bin/echo "\047[1A\047[\$30D\047[2K- Processed \${zot} configuration: 100% (\${dotenvcnt}/\${dotenvcnt})"
    else
      /bin/echo "Processing \${zot} configuration...: 100% (\${filecnt}/\${dotenvcnt})"
    fi
    unset dotenvs dotenvcnt filecnt
  fi
fi
PATH=\${ZOPEN_ROOTFS}/usr/local/bin:\${ZOPEN_ROOTFS}/usr/bin:\${ZOPEN_ROOTFS}/bin:\${ZOPEN_ROOTFS}/boot:\$(sanitizeEnvVar \"\${PATH}\" \":\" \"^\${ZOPEN_PKGINSTALL}/.*\$\")
export PATH=\$(deleteDuplicateEntries \"\${PATH}\" \":\")
LIBPATH=\${ZOPEN_ROOTFS}/usr/local/lib:\${ZOPEN_ROOTFS}/usr/lib:\$(sanitizeEnvVar "\${LIBPATH}" ":" "^\${ZOPEN_PKGINSTALL}/.*\$")
export LIBPATH=\$(deleteDuplicateEntries \"\${LIBPATH}\" \":\")
MANPATH=\${ZOPEN_ROOTFS}/usr/local/share/man:\${ZOPEN_ROOTFS}/usr/local/share/man/\%L:\${ZOPEN_ROOTFS}/usr/share/man:\${ZOPEN_ROOTFS}/usr/share/man/\%L:\$(sanitizeEnvVar \"\${MANPATH}\" \":\" \"^\${ZOPEN_PKGINSTALL}/.*\$\")
export MANPATH=\$(deleteDuplicateEntries \"\${MANPATH}\" \":\")

unset tmp FIFO_PIPE_DOTENVS FIFO_PIPE_STDOUT

# Unset traps
trap - EXIT INT TERM QUIT HUP
EOF

}

isPackageActive(){
  pkg="$1"
  printDebug "Checking if '${pkg}' is installed and active"
  installedPackage=$(cd "${ZOPEN_PKGINSTALL}" && zosfind . -name ".active" | grep "/\/${pkg}-/")
  cmdrc=$?
  # Return 1 for true/Package is Active, 0 for false/Package is not active
  [ "${cmdrc}" -eq 0 ] && return 1 || return 0
}

curlCmd()
{
  # Take the list of parameters and concat them with
  # any custom parameters the user requires in ZOPEN_CURL_PARAMS
  curl ${ZOPEN_CURL_PARAMS} $*
}

validateReleaseLine()
{
  echo "$1" | awk '
    toupper($1)=="DEV"    {print toupper($0)}
    toupper($1)=="STABLE" {print toupper($0)}
                          { print ""}
  '
}

# Attempt to fully dereference a symlink without any bashisms or arcane set logic
# using some simplistic (recursive!) logic
deref()
{
  testpath="$1"
  if [ -L "${testpath}" ]; then
    child=$(basename "${testpath}")
    symlink=$(ls -l "${testpath}" | sed 's/.*-> \(.*\)/\1/')
    parent=$(dirname "${testpath}")
    relpath="${parent}/${symlink}"
    relparent=$(dirname "${relpath}")
    abspath=$(cd "${relparent}" && pwd -P)
    testpath="${abspath}/${child}"
    deref "${testpath}"
  else
    [ -n "${testpath}" ] && echo "${testpath}" && unset testpath
  fi
}

defineANSI()
{
  # Standard tty codes
  ESC="\047"
  ERASELINE="${ESC}[2K"
  CRSRHIDE="${ESC}[?25l"
  CRSRSHOW="${ESC}[?25h"

  # Color-type codes, needs explicit terminal settings
  if [ ! "${_BPX_TERMPATH-x}" = "OMVS" ] && [ -z "${NO_COLOR}" ] && [ ! "${FORCE_COLOR-x}" = "0" ] && [ -t 1 ] && [ -t 2 ]; then
    esc="\047"
    BLACK="${esc}[30m"
    RED="${esc}[31m"
    GREEN="${esc}[32m"
    YELLOW="${esc}[33m"
    BLUE="${esc}[34m"
    MAGENTA="${esc}[35m"
    CYAN="${esc}[36m"
    GRAY="${esc}[37m"
    BOLD="${esc}[1m"
    UNDERLINE="${esc}[4m"
    NC="${esc}[0m"
  else
    # unset esc RED GREEN YELLOW BOLD UNDERLINE NC

    esc=''
    BLACK=''
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    GRAY=''
    BOLD=''
    UNDERLINE=''
    NC=''
  fi
}

ansiline()
{
  deltax=$1
  deltay=$2
  echostr=$3
  if [ ${deltax} -gt 0 ]; then
    echostr="${ESC}[${deltax}A${echostr}"
  elif [ ${deltax} -lt 0 ]; then
    echostr="${ESC}[$(expr ${deltax} \* -1)A${echostr}"
  fi
  if [ ${deltay} -gt 0 ]; then
    echostr="${ESC}[${deltax}C${echostr}"
  elif [ ${deltay} -lt 0 ]; then
    echostr="${ESC}[$(expr ${deltax} \* -1)D${echostr}"
  fi
  /bin/echo "${echostr}"

}

getScreenCols()
{
  # Note tput does not handle ssh sessions too well...
  stty | awk -F'[/=;]' '/columns/ { print $4}' | tr -d " "
}

zossed()
{
  # Use the standard z/OS sed utility; If the sed package is installed
  # GNU sed becomes the dominant version which might change how
  # matching is performed
  /bin/sed "$@"
}

zosfind()
{
  # Use the standard z/OS find utility; If the findutils package is installed,
  # the installed find command takes precedence but is not compatible with the
  # standard zos find [regex searches for "-name" are not allowed, but
  # "-wholename" is not available on standard zosfind. For the tooling to be
  # consistent across platforms (where findutils is/is not installed) use the
  # standard zos version
  /bin/find "$@"
}

findrev()
{
  haystack="$1"
  needle="$2"
  while [ "${haystack}" != "" ] && [ "${haystack}" != "/" ] && [ "${haystack}" != "./" ] && [ ! -e "${haystack}/${needle}" ]; do
    haystack=${haystack%/*}
  done
  echo "${haystack}"
}

strtrim()
{
  echo "$1" | sed -e 's/^[ ]*//' -e 's/[ ]*$//'
}

defineEnvironment()
{
  # Required for proper operation of z/OS auto-conversion support
  export _BPXK_AUTOCVT=ON
  export _CEE_RUNOPTS="${_CEE_RUNOPTS} FILETAG(AUTOCVT,AUTOTAG) POSIX(ON)"
  export _TAG_REDIR_ERR=txt
  export _TAG_REDIR_IN=txt
  export _TAG_REDIR_OUT=txt

  # Required for proper operation of xlclang
  export _CC_CCMODE=1
  export _C89_CCMODE=1
  export _CXX_CCMODE=1

  # Required for proper operation of (USS shipped) sed
  export _UNIX03=YES

  # Use /bin/cat as the pager in case xlclang help is displayed, we don't want to wait for input
  export PAGER=/bin/cat

  # Set a default umask of read and execute for user and group
  umask 0022
}

#
# For now, explicitly specify /bin/echo to ensure we get the EBCDIC echo since the escape
# sequences are EBCDIC escape sequences
#
printColors()
{
  /bin/echo "$@"
}

mutexReq()
{
  mutex=$1
  lockdir="${ZOPEN_ROOTFS}/var/lock"
  [ -e lockdir ] || mkdir -p ${lockdir}
  mutex="${lockdir}/${mutex}"
  mypid=$(exec sh -c 'echo ${PPID}')
  if [ -e "${mutex}" ]; then
    lockedpid=$(cat ${mutex})
    {
      [ ! "${lockedpid}" = "${mypid}" ] && [ ! "${lockedpid}" = "${PPID}" ]
    } && kill -0 "${lockedpid}" 2> /dev/null && echo "Aborting, Active process '${lockedpid}' holds the '$2' lock: '${mutex}'" && exit -1
  fi
  addCleanupTrapCmd "rm -rf ${mutex}"
  echo "${mypid}" > ${mutex}
}

mutexFree()
{
  mutex=$1
  lockdir="${ZOPEN_ROOTFS}/var/lock"
  mutex="${lockdir}/${mutex}"
  [ -e "${mutex}" ] && rm -f ${mutex}
}

relativePath2()
{
  sourcePath=$1
  targetPath=$2
  currentIFS="${IFS}"
  IFS="/"
  relativePath=''
  set -- ${targetPath}
  for elem in ${sourcePath}; do
    if [ -z "${relativePath}" ]; then
      if [ "$1" = "${elem}" ]; then
        shift
        continue
      else
        relativePath="../${elem}"
      fi
    else
      if [ -z "$1" ]; then
        relativePath="${relativePath}/${elem}"
      else
        relativePath="../${relativePath}/${elem}"
      fi
    fi
    if [ $# -gt 0 ]; then
      shift
    fi
  done
  # if the target is longer than the source, there might be some additional
  # elements in the shifted $0 to append
  if [ $# -gt 0 ]; then
    relativePath=${relativePath}/$(echo $* | sed "s/ /\//g")
  fi
  IFS="${currentIFS}"
  echo "${relativePath}"
}

# Merges a package directory's symlinks into the main zopen root filesystem
mergeIntoSystem()
{
  name=$1         # Name of the package being processed
  versioneddir=$2 # The directory where the unpax occurred
  rootfs="$3"
  rebaseusr="$4"

  [ -z "${rebaseusr}" ] && rebaseusr="usr/local"

  currentDir="${PWD}"

  printDebug "Calculating the offset path to store from root"
  offset=$(dirname "${versioneddir#"${rootfs}"/}")
  version=$(basename ${versioneddir})
  tmptime=$(date +%Y%m%d%H%M%S)
  processingDir="${rootfs}/tmp/zopen.${tmptime}"
  printDebug "Temporary processing dir evaluated to: ${processingDir}"

  virtualStore="${processingDir}/${offset}"
  printDebug "Creating virtual store at: ${virtualStore}"
  mkdir -p "${virtualStore}"

  printDebug "Moving from main store location (unpax-dir) to processing store"
  mv "${versioneddir}" "${virtualStore}"

  printDebug "Creating main linked directory in store"
  cd "${virtualStore}" && ln -s "${version}" "${name}"

  printDebug "Creating virtual root directory structure"
  mkdir -p "${processingDir}/${rebaseusr}"

  printDebug "Generating relative symlinks in processing location"
  relpath=$(relativePath2 "${virtualStore}/${name}" "${processingDir}/${rebaseusr}")
  [ "${relpath}" = "/" ] && printError "Relative path calculated as root directory itself!?!"

  printDebug "Generating symlink tree"

  printDebug "Creating directory structure"
  cd "${virtualStore}/${name}" || printError "Unable to change to virtual store at '${virtualStore}/${name}'"
  # since 'ln *' doesn't invoke globbing to allow multiple files at once,
  # abuse the Recurse option; this results in "already exists" errors but
  # ignore them as the first call should generate the correct link but
  # subsequent calls would generate a symlink that has incorrect dereferencing
  # and ignoring them is actually faster than individually creating the links!
  zosfind . -type d | sort -r | while read dir; do
    dir=$(echo "${dir}" | sed "s#^./##")
    printDebug "Processing dir: ${dir}"
    [ "${dir}" = "." ] && continue
    mkdir -p "${processingDir}/${rebaseusr}/${dir}"
    cd "${processingDir}/${rebaseusr}/${dir}" || printError "Unable to change to processing directory '${processingDir}/${rebaseusr}/${dir}'"
    dirrelpath=$(relativePath2 "${virtualStore}/${name}/${dir}" "${processingDir}/${rebaseusr}/${dir}")
    ln -Rs "${dirrelpath}/" "." 2> /dev/null
  done

  printDebug "Moving unpaxed processing-directory back to main rootfs store"
  # this *must* be done before the merge step below or relative symlinks can't
  # work
  versioneddirname=$(basename "${versioneddir}")
  mv "${virtualStore}/${versioneddirname}" "${rootfs}/${offset}"

  tarfile="${name}.usr.tar"
  printDebug "Merge symlinks into main filesystem using tmp tar file ${tarfile}"

  printDebug "Generating intermediary tar file"
  # Need '-S' to allow long symlinks
  cd "${processingDir}" && tar -S -cf "${tarfile}" "usr"

  printDebug "Generating listing for remove processing (including main symlink)"
  echo "Installed files:" > "${versioneddir}/.links"
  tar tf "${processingDir}/${tarfile}" 2> /dev/null| sort -r >> "${versioneddir}/.links"
  
  printDebug "Extracting tar to rootfs"
  cd "${processingDir}" && tar xf "${tarfile}" -C "${rootfs}" 2> /dev/null

  printDebug "Cleaning temp resources"
  rm -rf "${processingDir}" 2> /dev/null

  printDebug "Switching to previous cwd - current work dir was purged"
  cd "${currentDir}" || printError "Unable to change to '${currentDir}'"

  printInfo "- Integration complete"
  return 0
}

# The following function will remove any orphaned symlinks left after either:
# - a different version has been installed (where the old symlinks are not reused for
#   that different version  version ie. the file has been removed from updated version
# - the main package->version-dir symlink has been removed (which renders any symlinks to
#   it as dangling so removable)
unsymlinkFromSystem()
{
  pkg=$1
  rootfs=$2
  dotlinks=$3
  newfilelist=$4

  if [ -e "${dotlinks}" ]; then
    printInfo "- Checking for obsoleted files in ${rootfs}/usr/ tree from ${pkg}"

    if [ -e "${newfilelist}" ]; then
      printDebug "Release change, so the list of changes to physically remove should be smaller"
      printDebug "Starting spinner..."
      progressHandler "spinner" "- Check complete" &
      ph=$!
      killph="kill -HUP ${ph} 2>/dev/null"
      addCleanupTrapCmd "${killph}"
      obsoleteList=$(diffFile "${dotlinks}" "${newfilelist}")
      echo "${obsoleteList}" | while read obsoleteFile; do
        [ -z "${obsoleteFile}" ] && return 0
        obsoleteFile="${ZOPEN_ROOTFS}/${obsoleteFile}"
        obsoleteFile="${obsoleteFile%% symbolic*}"
        printDebug "Checking obsoletefile '${obsoleteFile}'"
        if [ -L "${obsoleteFile}" ] && [ ! -e "${obsoleteFile}" ]; then
          # the linked-to file no longer exists (ie. the symlink is dangling)
          rm -f "${obsoleteFile}" > /dev/null 2>&1
        fi 
      done
      ${killph}  # if the timer is not running, the kill will fail
    else
      # Slower method needed to analyse each link to see if it has
      # become orphaned. Only relevent when removing a package as 
      # upgrades/alt-switching can supply a list of files
      # Use sed to skip header line in .links file
      # Note that the contents of the links file are ordered such that
      # processing occurs depth-first; if, after removing orphaned symlinks,
      # a directory is empty, then it can be removed.
      nfiles=$(sed '1d;$d' "${dotlinks}" | wc -l  | tr -d ' ')
  
      printDebug "Creating Temporary dirname file"
      tempDirFile="${ZOPEN_ROOTFS}/tmp/zopen.rmdir.${RANDOM}"
      tempTrash="${tempDirFile}.trash"
      [ -e "${tempDirFile}" ] && rm -f "${tempDirFile}" >/dev/null 2>&1
      touch "${tempDirFile}"
      addCleanupTrapCmd "rm -rf ${tempDirFile} 2>/dev/null"
      printDebug "Using temporary file ${tempDirFile}"
      printInfo "- Checking ${nfiles} potential links"
  
      rm_fileprocs=15
      [ -e "${rootfs}/etc/zopen/rm_fileprocs" ] && rm_fileprocs=$(cat "${rootfs}/etc/zopen/rm_fileprocs")
      threshold=$(( nfiles / rm_fileprocs))
      threshold=$(( threshold + 1 ))
      printDebug "Threshold of files per worker [files/procs] calculated as: ${threshold}"
      [ ${threshold} -le 50 ] && threshold=50 && printVerbose "Threshold below min: using 50" # Don't spawn too many
      printDebug "Starting spinner..."
      progressHandler "spinner" "- Complete" &
      ph=$!
      killph="kill -HUP ${ph}"
      addCleanupTrapCmd "${killph} 2>/dev/null"
  
      printDebug "Spawning as subshell to handle threading"
      # Note that this all must happen in a subshell as the above started
      # progressHandler is a signal-terminated process - and a wait issued in 
      # the parent will never complete until that ph is signalled/terminated!
      deletethreads=$(
        tid=0
        filenames=""
        while read filetounlink; do
          tid=$(( tid + 1 ))
          filetounlink=$(echo "${filetounlink}" | sed 's/\(.*\).symbolic.*/\1/')
          filenames=$(/bin/printf "%s\n%s" "${filenames}" "${filetounlink}")
          if [ "$(( tid % threshold ))" -eq 0 ]; then
            deletethread "${filenames}" "${tempDirFile}" &
            printDebug "Started delete thread: $!"
            filenames=""
          fi
        done <<EOF
$(sed '1d;$d' "${dotlinks}")
EOF
        if [ -n "${filenames}" ]; then
          # Handle when there are not enough to trigger the threshold of a new thread above,
          # there will still be items in the "array"
          deletethread "${filenames}" "${tempDirFile}" #&
          printDebug "Started delete thread: $!"
        fi
        wait 
      )
      ${killph} 2>/dev/null  # if the timer is not running, the kill will fail
      if [ -e "${tempDirFile}" ]; then
        ndirs=$(cat "${tempDirFile}" | uniq | wc -l  | tr -d ' ')
        printInfo "- Checking ${ndirs} dir links"
        for d in $(cat "${tempDirFile}" | uniq | sort -r) ; do 
          [ -d "${d}" ] && rmdir "${d}" >/dev/null 2>&1
        done
      fi
    fi
  else
    printWarning "Could not locate list of current links to verify, dangling links might be present; run 'zopen clean -d'"
  fi
}

deletethread()
{
  filestodelete="$1"
  tempDirFile="$2"
  echo "${filestodelete}" | while read filetounlink; do
    deletetask "${tempDirFile}" "${filetounlink}"
  done
}

deletetask()
{
  tempDirFile="$1"
  filename="$2"
  [ -z "${filename}" ] && return 0
  filename="${ZOPEN_ROOTFS}/${filename}"
  if [ -d "${filename}" ]; then
    # Add to the queue for checking once files are gone if unique
    ispresent=$(grep "^${filename}[ ]*$" "${tempDirFile}")
    if [ -z "${ispresent}" ]; then
      echo " ${filename} " >> "${tempDirFile}"
    else
      alreadyfound=""
    fi
  elif [ -L "${filename}" ]; then
    if [ ! -f "${filename}" ]; then
      # the linked-to file no longer exists (ie. the symlink is dangling)
      rm -f "${filename}" > /dev/null 2>&1
    fi
  else
    echo "Unprocessable file: '${filename}'" >> "${tempTrash}"
  fi
}



printDebug()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  if ${debug}; then
    printColors "${NC}${BLUE}${BOLD}:DEBUG:${NC}: '${1}'" >&2
  fi
  [ -n "${xtrc}" ] && set -x
  return 0
}

printVerbose()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  if ${verbose}; then
    printColors "${NC}${GREEN}${BOLD}VERBOSE${NC}: '${1}'" >&2
  fi
  [ -n "${xtrc}" ] && set -x
  return 0
}

printHeader()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  printColors "${NC}${YELLOW}${BOLD}${UNDERLINE}${1}${NC}" >&2
  [ -n "${xtrc}" ] && set -x
  return 0
}

runAndLog()
{
  printVerbose "$1"
  eval "$1"
  rc=$?
  if [ ! -z "${SSH_TTY}" ]; then
    chtag -r ${SSH_TTY}
  fi
  return "${rc}"
}

runLogProgress()
{
  printVerbose "$1"
  if [ -n "$2" ]; then
    printInfo "- $2"
  else
    printInfo "- Running"
  fi
  if [ -n "$3" ]; then
    completeText="$3"
  else
    completeText="Complete"
  fi
  progressHandler "spinner" "- ${completeText}" &
  ph=$!
  killph="kill -HUP ${ph}"
  addCleanupTrapCmd "${killph} 2>/dev/null"
  eval "$1"
  rc=$?
  if [ -n "${SSH_TTY}" ]; then
    chtag -r "${SSH_TTY}"
  fi
  ${killph} 2> /dev/null # if the timer is not running, the kill will fail
  return "${rc}"
}

spinloop()
{
  # in the absence of generic ms/ns reporting, spin-loop instead - not ideal
  # but without pre-reqing packages...
  i=$1
  while [ ${i} -ge 0 ]; do
    true > /dev/null
    i=$((i - 1))
  done
}

progressNetwork()
{
  # Loop until signal received
  icon="-----"
  ansiline 0 0 "${icon}"
  while :; do
    spinloop 1000
    case "${icon}" in
    '-----') icon='>----' ;; '>----') icon='->---' ;; '->---') icon='-->--' ;; '-->--') icon='--->-' ;; '--->-') icon='---->' ;;
    '---->') icon='----<' ;; '----<') icon='---<-' ;; '---<-') icon='--<--' ;; '--<--') icon='-<---' ;; '-<---') icon='<----' ;; '<----') icon='-----' ;;
    esac
    ansiline 1 -1 "${icon}"
  done
}

progressSpinner()
{
  # Loop until signal received
  icon="-"
  ansiline 0 0 "${icon}"
  while :; do
    spinloop 1000
    case "${icon}" in
    '-') icon='\' ;; '\') icon='|' ;; '|') icon='/' ;; '/') icon='-' ;;
    esac
    ansiline 1 -1 "${icon}"
  done
}

progressHandler()
{
  if [ ! "${_BPX_TERMPATH-x}" = "OMVS" ] && [ -z "${NO_COLOR}" ] && [ ! "${FORCE_COLOR-x}" = "0" ] && [ -t 1 ] && [ -t 2 ]; then
    [ -z "${-%%*x*}" ] && set +x # Disable -x debug if set for this process
    type=$1
    completiontext=$2 # Custom end text (when the process is complete)

    trapcmd="exit;"
    [ -n "${completiontext}" ] && trapcmd="/bin/echo \"\047[1A\047[30D\047[2K${completiontext}\"; ${trapcmd}"
    trap "${trapcmd}" HUP
    case "${type}" in
    "network") progressNetwork ;;
    *) progressSpinner ;;
    esac
  fi
}

runInBackgroundWithTimeoutAndLog()
{
  command="$1"
  timeout="$2"

  printVerbose "${command} with timeout of ${timeout}s"
  eval "${command} &; TEEPID=$!"
  PID=$!
  n=0
  while [ ${n} -le ${timeout} ]; do
    kill -0 "${PID}" 2> /dev/null
    if [ $? != 0 ]; then
      wait "${PID}"
      if [ -n "${SSH_TTY}" ]; then
        chtag -r "${SSH_TTY}"
      fi
      rc=$?
      return ${rc}
    else
      sleep 1
      n=$(expr ${n} + 1)
    fi
  done
  kill -9 ${PID}
  kill -9 "${TEEPID}"
  printError "TIMEOUT: (PID: ${PID}): ${command}"
}

printSoftError()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  printColors "${NC}${RED}${BOLD}***ERROR: ${NC}${RED}${1}${NC}" >&2
  [ -n "${xtrc}" ] && set -x
}

printError()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  printColors "${NC}${RED}${BOLD}***ERROR: ${NC}${RED}${1}${NC}" >&2
  [ -n "${xtrc}" ] && set -x
  mutexFree "zopen" # prevent lock from lingering around after an error
  cleanupFunction
  exit 4
}

printWarning()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  printColors "${NC}${YELLOW}${BOLD}***WARNING: ${NC}${YELLOW}${1}${NC}" >&2
  [ -n "${xtrc}" ] && set -x
  return 0;
}

printInfo()
{
  [ -z "${-%%*x*}" ] && set +x && xtrc="-x" || xtrc=""
  printColors "$1" >&2
  [ -n "${xtrc}" ] && set -x
  return 0;
}

# Used to input sensitive data - turns off echo to the screen for the input
getInputHidden()
{
  # Register trap-handler to try and ensure that we restore the screen to display
  # chars in the event the script is terminated early (eg. user hits CTRL-C instead of
  # answering the masked question)
  addCleanupTrapCmd "stty echo 2>/dev/null"
  stty -echo
  read zopen_input
  echo "${zopen_input}"
  stty echo
}

getInput()
{
  read zopen_input
  echo "${zopen_input}"
}

printElapsedTime()
{
  printType=$1
  functionName=$2
  startTime=$3
  elapsedTime=$((${SECONDS} - ${startTime}))

  elapsedTimeOutput="${functionName} completed in ${elapsedTime} seconds."

  case ${printType} in
  "info")
    printInfo "${elapsedTimeOutput}"
    ;;
  "verbose")
    printVerbose "${elapsedTimeOutput}"
    ;;
  esac
}

processConfig()
{
  export ZOPEN_QUICK_LOAD=1
  if [ -z "${ZOPEN_ROOTFS}" ]; then
    relativeRootDir="$(cd "$(dirname "$0")/../.." > /dev/null 2>&1 && pwd -P)"
    if [ -f "${relativeRootDir}/etc/zopen-config" ]; then
      # shellcheck source=/dev/null
      . "${relativeRootDir}/etc/zopen-config"
    else
      printError "Source the zopen-config prior to running $0"
    fi
  fi
}

checkIfConfigLoaded()
{
  if [ -z "${ZOPEN_CA}" ]; then
    errorMessage="\${ZOPEN_CA} was not set. Ensure zopen init has run and zopen-config has been sourced."
  fi
  if [ ! -r "${ZOPEN_CA}" ]; then
    errorMessage="Certificate at ${ZOPEN_CA} could not be accessed. Ensure zopen init has run and zopen-config has been sourced."
  fi

  if [ -n "${errorMessage}" ]; then
    if [ -r "${mydir}/../../../etc/zopen-config" ]; then
      relativeConfigDir="$(cd "$(dirname "${mydir}")/../../etc/" > /dev/null 2>&1 && pwd -P)"
      errorMessage="${errorMessage} Run '. ${relativeConfigDir}/zopen-config'  or add it to your .profile."
    fi
    printError "${errorMessage}"
  fi
}

parseDeps()
{
  dep="$1"
  version=$(echo "${dep}" | awk -F '[>=<]+' '{print $2}')
  if [ -z "${version}" ]; then
    operator=""
    dep=$(echo "${dep}" | awk -F '[>=<]+' '{print $1}')
  else
    operator=$(echo "${dep}" | awk -F '[0-9.]+' '{print $1}' | awk -F '^[a-zA-Z]+' '{print $2}')
    dep=$(echo "${dep}" | awk -F '[>=<]+' '{print $1}')
    case ${operator} in
    ">=") ;;
    "=") ;;
    *) printError "${operator} is not supported." ;;
    esac
    major=$(echo "${version}" | awk -F. '{print $1}')
    minor=$(echo "${version}" | awk -F. '{print $2}')
    if [ -z "${minor}" ]; then
      minor=0
    fi
    patch=$(echo "${version}" | awk -F. '{print $3}')
    if [ -z "${patch}" ]; then
      patch=0
    fi
    prerelease=$(echo "${version}" | awk -F. '{print $4}')
    if [ -z "${prerelease}" ]; then
      prerelease=0
    fi
  fi

  echo "${dep}|${operator}|${major}|${minor}|${patch}|${prerelease}"
}

compareVersions()
{
  v1="$1"
  v2="$2"
  awk -v v1="${v1}" -v v2="${v2}" '
  function vercmp(v1, v2) {
    n1 = split(v1, v1_array, ".")
    n2 = split(v2, v2_array, ".")

    for (i = 1; i <= n1 || i <= n2; i++) {
      if (v1_array[i] != v2_array[i]) {
        return (v1_array[i] < v2_array[i] ? -1 : 1)
      }
    }
    return 0
  }

  BEGIN {
    if (vercmp(v1, v2) >= 0) {
      exit 0
    } else {
      exit 1
    }
  }
  '

  return $?
}

validateVersion()
{
  version=$1
  operator=$2
  requestedVersion=$3
  dependency=$4
  if [ -n "${operator}" ] && [ -z "${version}" ]; then
    printVerbose "${operator} ${requestedVersion} requsted, but no version file found in ${versionPath}."
    return 1
  elif [ -n "${operator}" ] && ! compareVersions "${version}" "${requestedVersion}"; then
    printVerbose "${dependency} does not satisfy ${version} ${operator} ${requestedVersion}"
    return 1
  fi
  return 0
}

deleteDuplicateEntries()
{
  value=$1
  delim=$2
  echo "${value}${delim}" | awk -v RS="${delim}" '!($0 in a) {a[$0]; printf("%s%s", col, $0); col=RS; }' | sed "s/${delim}$//"
}

# reworked version of above to strip blank elements between delims
deleteDuplicateEntriesRedux()
{
  value=$1
  delim=$2
  echo "${value}" | awk -v RS="${delim}" -v ORS="${delim}" ' {gsub("^[ ]+|[ ]$", "", $0); if (NF>0 && !a[$0]++) {print } }' | sed "s/${delim}$//"
}

# Logging Types
LOG_E="ERROR"   # If there was a failure and a command failed
LOG_W="WARNING" # If an error occurred but there was a workaround/fallback
LOG_I="INFO"    # General information
LOG_A="AUDIT"   # Security-type log for admin activities

# Logging Categories - more than one possible for a log entry
CAT_CONFIG="C"  # Configuration change
CAT_FILE="F"    # File handling (eg. downloading)
CAT_INSTALL="I" # Install processing
CAT_NETWORK="N" # Network processing
CAT_PKG="P"     # Package handling
CAT_QUERY="Q"   # Query processing
CAT_REMOVE="R"  # Removal handling
CAT_SYS="S"     # Related to the underlying native z/OS system
CAT_ZOPEN="Z"   # Related to the zopen system itself

syslog()
{
  fd=$1           # file
  type=$2         # LOG_? type as defined above
  categories=$3   # CAT_? type as defined above
  module=$4       # zopen-<MODULE>
  location=$5     # function
  msg=$6          # Message text
  if [ ! -e "${fd}" ]; then
    mkdir -p "$(dirname "${fd}")"
    touch "${fd}"
  fi
  echo "$(date +"%F %T") $(id | cut -d' ' -f1)::${module}:${type}:${categories}:${location}:${msg}" >> "${fd}"
}

downloadJSONCache()
{
  if [ -z "${JSON_CACHE}" ]; then
    JSON_CACHE="${ZOPEN_ROOTFS}/var/cache/zopen/zopen_releases.json"
    JSON_TIMESTAMP="${ZOPEN_ROOTFS}/var/cache/zopen/zopen_releases.timestamp"
    JSON_TIMESTAMP_CURRENT="${ZOPEN_ROOTFS}/var/cache/zopen/zopen_releases.timestamp.current"
    if ! curlCmd -L -s -I "${ZOPEN_JSON_CACHE_URL}" -o "${JSON_TIMESTAMP_CURRENT}"; then
      printError "Failed to obtain json cache timestamp from ${ZOPEN_JSON_CACHE_URL}"
    fi
    chtag -tc 819 "${JSON_TIMESTAMP_CURRENT}"

    if [ -f "${JSON_CACHE}" ] && [ -f "${JSON_TIMESTAMP}" ] && [ "$(grep 'Last-Modified' "${JSON_TIMESTAMP_CURRENT}")" = "$(grep 'Last-Modified' "${JSON_TIMESTAMP}")" ]; then
      return
    fi

    mv "${JSON_TIMESTAMP_CURRENT}" "${JSON_TIMESTAMP}"
    if ! curlCmd -L -s -o "${JSON_CACHE}" "${ZOPEN_JSON_CACHE_URL}"; then
      printError "Failed to obtain json cache from ${ZOPEN_JSON_CACHE_URL}"
    fi
    chtag -tc 819 "${JSON_CACHE}"
  fi

  if [ ! -f "${JSON_CACHE}" ]; then
    printError "Could not download json cache from ${ZOPEN_JSON_CACHE_URL}"
  fi
}

getReposFromGithub()
{
  downloadJSONCache
  repo_results="$(cat "${JSON_CACHE}" | jq -r '.release_data | keys[]')"
}

getAllReleasesFromGithub()
{
  downloadJSONCache
  repo="$1"
  releases="$(jq -e -r '.release_data."'${repo}'"' "${JSON_CACHE}")"
  if [ $? -ne 0 ]; then
    printError "Could not get all releases for ${repo}"
  fi
}

initDefaultEnvironment()
{
  export ZOPEN_OLD_PATH="${PATH}"     # Preserve PATH in case scripts need to access it
  export ZOPEN_OLD_LIBPATH="${LIBPATH}" # Preserve LIBPATH in case scripts need to access it
  export PATH="$(getconf PATH)"
  export _CEE_RUNOPTS="FILETAG(AUTOCVT,AUTOTAG) POSIX(ON)"
  unset MANPATH
  export LIBPATH="/usr/lib"
  export STEPLIB=none
}

#
# checkWritable prints a message and exits if the directory above INCDIR
# is not writable. This is a safe location to check for and should be
# writable on a 'dev' environment
#
checkWritable()
{
  if [ -z "${INCDIR}" ]; then
    echo "Internal error. Caller has to have set INCDIR" >&2
    exit 16
  fi
  ROOTDIR="$(cd "${INCDIR}/../" > /dev/null 2>&1 && pwd -P)"
  if ! [ -w "${ROOTDIR}" ]; then
    printError "Tried to run an update operation (${ME}) in a read-only tools distribution" >&2
  fi
}

installDependencies()
(
  name=$1
  printVerbose "List of dependencies to install: ${dependencies}"
  skipupgrade_lcl=${skipupgrade}
  skipupgrade=true
  echo "${dependencies}" | xargs | tr ' ' '\n' | sort | while read dep; do
    printDebug "Removing '${dep}' from dependency queue '${dependencies}'"
    # done in case of dependency chain that specifies the same dependency more than once!
    dependencies=$(echo "${dependencies}" | sed -e "s/${dep}//" | tr -s ' ')
    printDebug "Checking if package already installed this session"
    alreadyInstalled=$(echo "${sessionList}" | sed -e "s/.*\(${dep}\).*//")
    if [ -z "${alreadyInstalled}" ]; then
      handlePackageInstall "${dep}"
    else
      printDebug "Package '${dep}' installed earlier; no install required"
    fi
  done
  skipupgrade=${skipupgrade_lcl}
)

handlePackageInstall(){
  printDebug "Checking whether installing direct from pax files or via Github repo"
  if ! ${paxinstall}; then
    printDebug "Using standard Github repo"
    fullname="$1"
    printDebug "Name to install: ${fullname}, parsing any version ('=') or tag ('%') has been specified"
    name=$(echo "${fullname}" | sed -e 's#[=%].*##')
    repo="${name}"
    versioned=$(echo "${fullname}" | cut -s -d '=' -f 2)
    tagged=$(echo "${fullname}" | cut -s -d '%' -f 2)
    printDebug "Name:${name};version:${versioned};tag:${tagged};repo:${repo}"
    printHeader "Installing package: ${name}"
    [ -z "${paxrepodir}" ] && getAllReleasesFromGithub "${repo}"
  else 
    printDebug "Using native pax files to install"
    reponame="$1"
    if [ "${reponame}" = "${reponame%%.zos.pax.Z}" ]; then
      printDebug "Package did not have .zos.pax.Z suffix - attempt to locate suitable pax"

      printDebug "Check [in order] cli paxrootdir -> system paxrootdir -> current dir for repo to check"
      testpaxRepo=""
      [ -n "${paxrepodir}" ] && testpaxRepo="${paxrepodir}"
      [ -n "${testpaxRepo}" ] && [ ! -r "${testpaxRepo}" ] && printError "Could not access location '${testpaxRepo}' from parameter --paxrepodir. Check parameter setting and retry command"
      [ -z "${testpaxRepo}" ] && [ -e "${ZOPEN_ROOTFS}/etc/zopen/paxrepodir" ] && tespaxRepo=$(cat "${ZOPEN_ROOTFS}/etc/zopen/paxrepodir")
      [ -n "${testpaxRepo}" ] && [ ! -r "${testpaxRepo}" ] && printError "Unable to read system repository at location '${tespaxRepo}'. Correct system setting in '${ZOPEN_ROOTFS}/etc/zopen/paxrepodir' and retry command"
      [ -z "${testpaxRepo}" ] && testpaxRepo="./"
      prefix="${reponame}-" 
      printDebug "Finding paxes prefixed '${prefix}' in '${testpaxRepo}'"
      # Note, not cd'ing to dir means we get full pax name - need the "/" at the end though
      #(heads -1 or tails -1 - need to test multiple pax for install)
      paxRepo=$(zosfind "${testpaxRepo%%/}/" ! -name "${testpaxRepo%%/}/" -prune -a -type f |grep "${prefix}" |sort|tail -n 1)
      printVerbose "Found pax '${paxRepo}' as candidate for install for package '${reponame}'"
    else
      printDebug "Parameter passed in had suffix indicating pax file; try to locate file..."
      if [ -r "${reponame}" ]; then
        printVerbose "Found file at location specified '${reponame}'; using as-is"
        paxRepo="${reponame}"
      else
        printDebug "Attempt to locate rpm file in current directory or in configured locations [if set]"
        paxfilename=$(basename "${reponame}") 
        printDebug "Checking current directory '${PWD}'"
        testpaxRepo="./${paxfilename}"
        if [ -r "${testpaxRepo}" ]; then
          printVerbose "Found ${paxfilename} as '${testpaxRepo}'; installing"
          paxRepo="${testpaxRepo}"
        elif [ -n "${paxrepodir}" ]; then
          printVerbose "Using repository '${paxrepodir}' as specified on cli"
          testpaxRepo="${paxrepodir}/${paxfilename}"
          if [ -r "${testpaxRepo}" ]; then
            printVerbose "Found ${paxfilename} as '${testpaxRepo}'; installing"
            paxRepo="${testpaxRepo}"
          fi
        elif [ -e "${ZOPEN_ROOTFS}/etc/zopen/paxrepodir" ]; then
          printDebug "Using [single] repository specified from system config '${ZOPEN_ROOTFS}/etc/zopen/paxrepodir'"
          paxrepodir=$(cat "${ZOPEN_ROOTFS}/etc/zopen/paxrepodir")
          printVerbose "Trying repository at system configured location '${repodir}'"
          testpaxRepo="${paxrepodir}/${paxfilename}"
          if [ -r "${testpaxRepo}" ]; then
            printVerbose "Found ${paxfilename} as '${testpaxRepo}'; installing"
            paxRepo="${testpaxRepo}"
          fi
        else
          printError "Cannot locate specified pax file '${reponame}' to install. Validate filename, repository or permissions and retry request"
        fi
      fi
    fi

    [ -z "${paxRepo}" ] && printError "Could not locate pax file for '${reponame}'. Validate filename, repository or permissions and retry request."      
    printDebug "Installing a custom-repo pax '${paxRepo}', need to find and break it open and get the metadata first"
    tmptime=$(date +%Y%m%d%H%M%S)
    tmpUnpaxDir="${rootfs}/tmp/zopen.${tmptime}"
    printVerbose "Temporary processing dir evaluated to: ${tmpUnpaxDir}"
    [ -e "${tmpUnpaxDir}" ] && rm -rf "${tmpUnpaxDir}"
    mkdir -p "${tmpUnpaxDir}" >/dev/null 2>&1
    #addCleanupTrapCmd "rm -rf ${tmpUnpaxDir}"
    paxredirect="-s %[^/]*/%${tmpUnpaxDir}/%"
    
    if ! runLogProgress "pax -rf ${paxRepo} -p p ${paxredirect} ${redirectToDevNull} " "Expanding ${paxRepo}" "Expanded"; then
      printError "Errors unpaxing '${paxRepo}'"
      continue;
    fi
    printDebug "Checking pax for metadata file(s): README.md"

    printDebug "Attempting to calculate package name..."
    if [ -r "${tmpUnpaxDir}/README.md" ]; then
      printDebug "Found README.md - first line *might* be package title"
      name=$(head -1 "${tmpUnpaxDir}/README.md" | awk '{print $NF}')
    fi
    if [ -z "${name}" ]; then 
        # Fallback to pax file name
        name=$(basename "${paxRepo%%-*}")
        printVerbose "Using '${name}' as package name"
    fi
    name="${name%port}"
    [ -z "${name}" ] && printError "Could not determine package name from pax file metadata"
    printVerbose "Using '${name}' as package name"    

    printDebug "Copying specified pax '${paxRepo}' for package '${name}' into correct location for install '${downloadDir}'"
    downloadFile=$(basename "${paxRepo}")
    # if already exits, skip copy
    [ ! -e "${downloadDir}/${downloadFile}" ] && cp -R "${paxRepo}" "${downloadDir}"
  fi

  if ${localInstall}; then
    printDebug "Local install to current directory"
    rootInstallDir="${PWD}"
  else
    printDebug "Setting install root to: ${ZOPEN_PKGINSTALL}"
    rootInstallDir="${ZOPEN_PKGINSTALL}"
  fi
  originalFileVersion=""
  printDebug "Checking for meta files in '${rootInstallDir}/${name}/${name}'"
  printDebug "Finding version/release information"
  if [ -e "${rootInstallDir}/${name}/${name}/.releaseinfo" ]; then
    originalFileVersion=$(cat "${rootInstallDir}/${name}/${name}/.releaseinfo")
    printDebug "Found originalFileVersion=${originalFileVersion} (port is already installed)"
  elif [ -e "${rootInstallDir}/${name}/${name}/.version" ]; then
    originalFileVersion=$(cat "${rootInstallDir}/${name}/${name}/.version")
    printDebug "Found originalFileVersion=${originalFileVersion} (port is already installed)"
  else
    printDebug "Could not detect existing installation at ${rootInstallDir}/${name}/${name}"
  fi

  printDebug "Finding releaseline information"
  installedReleaseLine=""
  if [ -e "${rootInstallDir}/${name}/${name}/.releaseline" ]; then
    installedReleaseLine=$(cat "${rootInstallDir}/${name}/${name}/.releaseline")
    printVerbose "Installed product from releaseline: ${installedReleaseLine}"
  else
    printVerbose "No current releaseline for package"
  fi
  
  printDebug "Checking whether installing direct from a pax [from a custom repo]"
  if ! ${paxinstall}; then
    releasemetadata=""
    downloadURL=""
    # Options where the user explicitly sets a version/tag/releaseline currently ignore any configured release-line,
    # either for a previous package install or system default
    if [ ! "x" = "x${versioned}" ]; then
      printDebug "Specific version ${versioned} requested - checking existence and URL"
      requestedMajor=$(echo "${versioned}" | awk -F'.' '{print $1}')
      requestedMinor=$(echo "${versioned}" | awk -F'.' '{print $2}')
      requestedPatch=$(echo "${versioned}" | awk -F'.' '{print $3}')
      requestedSubrelease=$(echo "${versioned}" | awk -F'.' '{print $4}')
      requestedVersion="${requestedMajor}\\\.${requestedMinor}\\\.${requestedPatch}\\\.${requestedSubrelease}"
      printDebug "Finding URL for latest release matching version prefix: requestedVersion: ${requestedVersion}"
      releasemetadata=$(/bin/printf "%s" "${releases}" | jq -e -r '. | map(select(.assets[].name | test("'${requestedVersion}'")))[0]')
    elif [ ! "x" = "x${tagged}" ]; then
      printDebug "Explicit tagged version '${tagged}' specified. Checking for match"
      releaseMetadata=$(/bin/printf "%s" "${releases}" | jq -e -r '.[] | select(.tag_name == "'${tagged}'")')
      printDebug "Use quick check for asset to check for existence of metadata for specific messages"
      asset=$(/bin/printf "%s" "${releasemetadata}" | jq -e -r '.assets[0]')
      if [ $? -ne 0 ]; then
        printError "Could not find release tagged '${tagged}' in repo '${repo}'"
      fi
    elif ${selectVersion}; then
      # Explicitly allow the user to select a release to install; useful if there are broken installs
      # as a known good release can be found, selected and pinned!
      printDebug "List individual releases and allow selection"
      i=$(/bin/printf "%s" "${releases}" | jq -r 'length - 1')
      printInfo "Versions available for install:"
      /bin/printf "%s" "${releases}" | jq -e -r 'to_entries | map("\(.key): \(.value.tag_name) - \(.value.assets[0].name) - size: \(.value.assets[0].expanded_size/ (1024 * 1024))mb")[]'
  
      printDebug "Getting user selection"
      valid=false
      while ! ${valid}; do
        echo "Enter version to install (0-${i}): "
        read selection < /dev/tty
        if [ ! -z $(echo "${selection}" | sed -e 's/[0-9]*//') ]; then
          echo "Invalid input, must be a number between 0 and ${i}"
        elif [ "${selection}" -ge 0 ] && [ "${selection}" -le "${i}" ]; then
          valid=true
        fi
      done
      printVerbose "Selecting item ${selection} from array"
      releasemetadata="$(/bin/printf "%s" "${releases}" | jq -e -r ".[${selection}]")"
  
    elif [ -n "${releaseLine}" ]; then  
      printDebug "Install from release line '${releaseLine}' specified"
      validatedReleaseLine=$(validateReleaseLine "${releaseLine}")
      if [ -z "${validatedReleaseLine}" ]; then
        printError "Invalid releaseline specified: '${releaseLine}'; Valid values: DEV or STABLE"
      fi
      printDebug "Finding latest asset on the release line"
      releasemetadata="$(/bin/printf "%s" "${releases}" | jq -e -r '. | map(select(.tag_name | startswith("'${releaseLine}'")))[0]')"
      printDebug "Use quick check for asset to check for existence of metadata"
      asset="$(/bin/printf "%s" "${releasemetadata}" | jq -e -r '.assets[0]')"
      if [ $? -ne 0 ]; then
        printError "Could not find release-line ${releaseLine} for repo: ${repo}"
      fi
      
    else
      printDebug "No explicit version/tag/releaseline, checking for pre-existing package&releaseline"
      if [ -n "${installedReleaseLine}" ]; then
        printDebug "Found existing releaseline '${installedReleaseLine}', restricting to only that releaseline"
        validatedReleaseLine="${installedReleaseLine}"  # Already validated when stored
      else 
        printDebug "Checking for system-configured releaseline"
        sysrelline=$(cat "${ZOPEN_ROOTFS}/etc/zopen/releaseline" | awk ' {print toupper($1)}')
        printDebug "Validating value: ${sysrelline}"
        validatedReleaseLine=$(validateReleaseLine "${sysrelline}")
        if [ -n "${validatedReleaseLine}" ]; then
          printDebug "zopen system configured to use releaseline '${sysrelline}'; restricting to that releaseline"
        else
          printWarning "zopen misconfigured to use an unknown releaseline of '${sysrelline}'; defaulting to STABLE packages"
          printWarning "Set the contents of '${ZOPEN_ROOTFS}/etc/zopen/releaseline' to a valid value to remove this message"
          printWarning "Valid values are: DEV | STABLE"
          validatedReleaseLine="STABLE"
        fi
      fi

      printDebug "Parsing releases: ${releases}"
      # We have some situations that could arise
        # 1. the port being installed has no releaseline tagging yet (ie. no releases tagged STABLE_* or DEV_*)
        # 2. system is configured for STABLE but only has DEV stream available
        # 3. system is configured for DEV but only has DEV stream available
        # 4. the port being installed has got full releaseline tagging
        # The issue could arise that the user has switched the system from DEV->STABLE or vice-versa so package
        # stream mismatches could arise but in normal case, once a package is installed [that has releaseline tagging]
        # then that specific releaseline will be used
      printDebug "Finding any releases tagged with ${validatedReleaseLine} and getting the first (newest/latest)"
      releasemetadata="$(/bin/printf "%s" "${releases}" | jq -e -r '. | map(select(.tag_name | startswith("'${validatedReleaseLine}'")))[0]')"
      printDebug "Use quick check for asset to check for existence of metadata"
      asset="$(/bin/printf "%s" "${releasemetadata}" | jq -e -r '.assets[0]')"
      if [ $? -eq 0 ]; then
        # Case 4...
        printVerbose "Found a specific '${validatedReleaseLine}' release-line tagged version; installing..."
      else
        # Case 2 & 3
        printDebug "No releases on releaseline '${validatedReleaseLine}'; checking alternative releaseline"
        alt=$(echo "${validatedReleaseLine}" | awk ' /DEV/ { print "STABLE" } /STABLE/ { print "DEV" }')
        releasemetadata="$(/bin/printf "%s" "${releases}" | jq -e -r '. | map(select(.tag_name | startswith("'${alt}'")))[0]')"
        printDebug "Use quick check for asset to check for existence of metadata"
        asset="$(/bin/printf "%s" "${releasemetadata}" | jq -e -r '.assets[0]')"
        if [ $? -eq 0 ]; then
          printDebug "Found a release on the '${alt}' release line so release tagging is active"
          if [ "DEV" = "${validatedReleaseLine}" ]; then
            # The system will be configured to use DEV packages where available but if none, use latest
            printInfo "No specific DEV releaseline package, using latest available"
            releasemetadata="$(/bin/printf "%s" "${releases}" | jq -e -r ".[0]")"
          else
            printVerbose "The system is configured to only use STABLE releaseline packages but there are none"
            printInfo "No release available on the '${validatedReleaseLine}' releaseline."
          fi
        else
          # Case 1 - old package that has no release tagging yet (no DEV or STABLE), just install latest
          printVerbose "Installing latest release"
          releasemetadata="$(/bin/printf "%s" "${releases}" | jq -e -r ".[0]")"
        fi
      fi
    fi
    printDebug "Getting specific asset details from metadata: ${releasemetadata}"
    if [ -z "${asset}" ] || [ "null" = "${asset}" ]; then
      printDebug "Asset not found during previous logic; setting now"
      asset=$(/bin/printf "%s" "${releasemetadata}" | jq -e -r '.assets[0]')
    fi
    if [ "x" = "x${asset}" ]; then
      printError "Unable to determine download asset for ${name}"
    fi
  
    tagname=$(/bin/printf "%s" "${releasemetadata}" | jq -e -r ".tag_name" | sed "s/\([^_]*\)_.*/\1/")
    installedReleaseLine=$(validateReleaseLine "${tagname}" )
  
    downloadURL=$(/bin/printf "%s" "${asset}" | jq -e -r '.url')
    size=$(/bin/printf "%s" "${asset}" | jq -e -r '.expanded_size')
  
    if [ "x" = "x${downloadURL}" ]; then
      printError "Unable to determine download location for ${name}"
    fi
    downloadFile=$(basename "${downloadURL}")
    downloadFileVer=$(echo "${downloadFile}" |sed -E 's/.*-(.*)\.zos\.pax\.Z/\1/')
    printVerbose "Downloading port from URL: ${downloadURL} to file: ${downloadFile} (ver=${downloadFileVer})"
  else
    printVerbose "Installing package '${name}' from pax file '${paxRepo}'"
    printDebug "Pax was expanded to '${tmpUnpaxDir}' previously"
    downloadFilePrfx="${paxRepo%.zos.pax.Z}"
    downloadFileVer="${downloadFilePrfx##*-}"
    size=$(du -s "${tmpUnpaxDir}" | awk ' {print $1}') # in 512-blocks
    [ -z "${size}" ] && printError "Could not calculate directory size"
    size=$(echo "${size} * 512" | bc)
  fi

  if ${downloadOnly}; then
    printVerbose "Skipping installation, downloading only"
  else
    printDebug "Install=${downloadFileVer};Original=${originalFileVersion};${upgradeInstalled};${installOrUpgrade};${reinstall}"
    if [ "${downloadFileVer}" = "${originalFileVersion}" ]; then
      if ! ${reinstall}; then
        printInfo "${NC}${GREEN}Package ${name} is already installed at the requested version: ${downloadFileVer}${NC}"
        return;
      fi
      printInfo "- Reinstalling version '${downloadFileVer}' of ${name}..."
    fi

    printDebug "Checking if package is not installed but scheduled for upgrade"
    if [ "x" = "x${originalFileVersion}" ]; then
      printDebug "No previous version found"
      if ${installOrUpgrade}; then
        printDebug "Package ${name} was not installed so not upgrading but installing"
      elif ${upgradeInstalled}; then
        printError "Package ${name} can not be upgraded as it is not installed!"
        continue;
      fi
      unInstallOldVersion=false
      printInfo "- Installing ${name}..."
    elif ${skipupgrade}; then
      printInfo "Package ${name} has a newer release '${downloadFileVer}' but explicitly skipping"
      continue;
    elif ! ${setactive}; then
      printVerbose "Current version '${originalFileVersion}' will remain active"
      unInstallOldVersion=false
    else
      printVerbose "Previous version '${originalFileVersion}' installed"
      if [ -e "${rootInstallDir}/${name}/${name}/.pinned" ]; then
        printWarning "- Version '${originalFileVersion}' has been pinned; upgrade to '${downloadFileVer}' skipped"
        syslog "${ZOPEN_LOG_PATH}/audit.log" "${LOG_A}" "${CAT_PACKAGE},${CAT_INSTALL}" "DOWNLOAD" "handlePackageInstall" "Attempt to change pinned package '${name}' skipped"
        continue;
      else
        printInfo "- Replacing ${name} version '${originalFileVersion}' with '${downloadFileVer}'"
        unInstallOldVersion=true
        currentversiondir=$(cd "${rootInstallDir}/${name}/${name}" && pwd -P)
        currentlinkfile="${currentversiondir}/.links"
      fi
    fi
  fi
  printDebug "Ensuring we are in the correct working download location '${downloadDir}'"
  cd "${downloadDir}" || printError "Unable to change to download directory '${downloadDir}'"

  if [ ! ${downloadOnly} ] || [ ! ${localInstall} ]; then
    printDebug "Checking current directory for already downloaded package [file name comparison]"
    location="current directory"
  else
    printDebug "Checking cache for already downloaded package [file name comparison]"
    location="zopen package cache"
  fi

  pax=${downloadFile}
  if [ -f "${pax}" ]; then
    printVerbose "- Found existing file '${pax}' in ${location}"
  else
    printInfo "- Downloading ${pax} file from remote to ${location}..."
    if ! ${verbose}; then
      redirectToDevNull="2>/dev/null"
    fi

    progressHandler "network" "- Downloaded ${pax} file from remote to ${location}." &
    ph=$!
    killph="kill -HUP ${ph} 2>/dev/null"
    addCleanupTrapCmd "${killph}"

    if ! runAndLog "curlCmd -L '${downloadURL}' -O ${redirectToDevNull}"; then
      printError "Could not download from ${downloadURL}. Correct any errors and potentially retry"
      continue;
    fi
    ${killph}  # if the timer is not running, the kill will fail
    syslog "${ZOPEN_LOG_PATH}/audit.log" "${LOG_A}" "${CAT_NETWORK},${CAT_PACKAGE},${CAT_FILE}" "DOWNLOAD" "handlePackageInstall" "Downloaded remote file '${pax}'"
  fi
  if [ ! -f "${pax}" ]; then
    printError "${pax} was not found after download!?!"
  fi

  if ${downloadOnly}; then
    printVerbose "Pax was downloaded to local dir '${downloadDir}'"
  elif ${cacheOnly}; then
    printVerbose "Pax was downloaded to zopen cache '${downloadDir}'"
  else
    printDebug "Installing ${pax}"
    installdirname="${name}/${pax%.pax.Z}" # Use full pax name as default

    printVerbose "- Processing ${pax}..."
    baseinstalldir="."
    paxredirect=""
    if ! ${localInstall}; then
      baseinstalldir="${rootInstallDir}"
      paxredirect="-s %[^/]*/%${rootInstallDir}/${installdirname}/%"
      printDebug "Non-local install, extracting with '${paxredirect}'"
    else
      printVerbose "- Local install specified"
      paxredirect="-s %[^/]*/%${installdirname}/%"
      printDebug "Non-local install, extracting with '${paxredirect}'"
    fi

    megabytes=$(echo "scale=2; ${size} / (1024 * 1024)" | bc)
    printInfo "After this operation, ${megabytes} MB of additional disk space will be used."
    if ! ${yesToPrompts}; then
      while true; do
        printInfo "Do you want to continue? [y/n/a]"
        read continueInstall < /dev/tty
        case "${continueInstall}" in
          "y") break;;
          "n") mutexFree "zopen" && printInfo "Exiting..." && exit 0 ;;
          "a") yesToPrompts=true; break;;
          *) echo "?";;
        esac
      done
    fi

    printDebug "Check for existing directory for version '${installdirname}'"
    if [ -d "${baseinstalldir}/${installdirname}" ]; then 
      printVerbose "- Clearing existing directory and contents"
      rm -rf "${baseinstalldir}/${installdirname}"
    fi

    if  ! ${paxinstall}; then
      if ! runLogProgress "pax -rf ${pax} -p p ${paxredirect} ${redirectToDevNull}" "Expanding ${pax}" "Expanded"; then
        printWarning "Errors unpaxing, package directory state unknown"
        printInfo    "Use zopen alt to select previous version to ensure known state"
        continue;
      fi
    else
      printVerbose "Moving already expanded pax directory to expanded location"
      mkdir -p "${baseinstalldir}/${installdirname}" 2>/dev/null
      mv "${tmpUnpaxDir}/" "${baseinstalldir}/${installdirname}" >/dev/null 2?&1
    fi
    if ${localInstall}; then
      rm -f "${pax}"
    fi

    if ${setactive}; then
      if [ -L "${baseinstalldir}/${name}/${name}" ]; then
        printDebug "Removing old symlink '${baseinstalldir}/${name}/${name}'"
        rm -f "${baseinstalldir}/${name}/${name}"
      fi
      if ! ln -s "${baseinstalldir}/${installdirname}" "${baseinstalldir}/${name}/${name}"; then
        printError "Could not create symbolic link name"
      fi 
    fi 

    printDebug "Adding version '${downloadFileVer}' to info file"
    # Add file version information as a .releaseinfo file
    echo "${downloadFileVer}" > "${baseinstalldir}/${installdirname}/.releaseinfo"

    # Check for a .version file from the pax - if present good, if not
    # generate one from the file name as the tag isn't granular enough to really
    # be used in dependency checks
    if [ ! -f "${baseinstalldir}/${installdirname}/.version" ]; then
      echo "${downloadFileVer}" > "${baseinstalldir}/${installdirname}/.version"
    fi

    printDebug "Adding releaseline '${installedReleaseLine}' metadata to ${baseinstalldir}/${installdirname}/.releaseline"
    echo "${installedReleaseLine}" > "${baseinstalldir}/${installdirname}/.releaseline"

    if ${setactive}; then
      if ! ${nosymlink}; then
        mergeIntoSystem "${name}" "${baseinstalldir}/${installdirname}" "${ZOPEN_ROOTFS}" 
        misrc=$?
        printDebug "The merge complete with: ${misrc}"
      fi

      printVerbose "- Checking for env file"
      if [ -f "${baseinstalldir}/${name}/${name}/.env" ] || [ -f "${baseinstalldir}/${name}/${name}/.appenv" ]; then
        printVerbose "- .env file found, adding to profiled processing"
        mkdir -p "${ZOPEN_ROOTFS}/etc/profiled/${name}"
        cat << EOF > "${ZOPEN_ROOTFS}/etc/profiled/${name}/dotenv"
curdir=\$(pwd)
cd "${baseinstalldir}/${name}/${name}" >/dev/null 2>&1
# If .appenv exists, source it as it's quicker
if [ -f ".appenv" ]; then
  . ./.appenv
elif [ -f ".env" ]; then
  . ./.env
fi
cd \${curdir}  >/dev/null 2>&1
EOF
        printVerbose "- Running any setup scripts"
        cd "${baseinstalldir}/${name}/${name}" && [ -r "./setup.sh" ] && ./setup.sh
      fi
    fi
    if ${unInstallOldVersion}; then
      printDebug "New version merged; checking for orphaned files from previous version"
      # This will remove any old symlinks or dirs that might have changed in an upgrade
      # as the merge process overwrites existing files to point to different version
      unsymlinkFromSystem "${name}" "${ZOPEN_ROOTFS}" "${currentlinkfile}" "${baseinstalldir}/${name}/${name}/.links"
    fi

    if ${setactive}; then
      printDebug "Marking this version as installed"
      touch "${baseinstalldir}/${name}/${name}/.active"
      installedList="${name} ${installedList}"
      syslog "${ZOPEN_LOG_PATH}/audit.log" "${LOG_A}" "${CAT_INSTALL},${CAT_PACKAGE}" "DOWNLOAD" "handlePackageInstall" "Installed package:'${name}';version:${downloadFileVer};install_dir='${baseinstalldir}/${installdirname}';"
    fi

    if ${doNotInstallDeps}; then
        printVerbose "- Skipping dependency installation"
    elif ${reinstall}; then
      printDebug "- Reinstalling so no dependency reinstall (unless explicitly listed)"
    else
      printVerbose "- Checking for runtime dependencies"
      printDebug "Checking for .runtimedeps file"
      if [ -e "${baseinstalldir}/${name}/${name}/.runtimedeps" ]; then
        dependencies=$(cat "${baseinstalldir}/${name}/${name}/.runtimedeps")
      fi
      printDebug "Checking for runtime dependencies from the git metadata"
      if echo "${statusline}" | grep "Runtime Dependencies:" >/dev/null; then
        gitmetadependencies="$(echo "${statusline}" | sed -e "s#.*Runtime Dependencies:<\/b> ##" -e "s#<br />.*##")"
        if [ ! "${gitmetadependencies}" = "No dependencies" ]; then
          dependencies="${dependencies} ${gitmetadependencies}"
        fi
      fi
      dependencies=$(deleteDuplicateEntries "${dependencies}" " ")
      if [ ! "x" = "x${dependencies}" ]; then
        printVerbose "- ${name} depends on: ${dependencies}"
        printInfo "- Installing dependencies"
        installDependencies "${name}" "${dependencies}"
      else
        printVerbose "- No runtime dependencies found"
      fi
    fi
    sessionList="${sessionLis} ${name}"
    printInfo "${NC}${GREEN}Successfully installed ${name}${NC}"
  fi # (download only)
}

zopenInitialize()
{
  # Create the cleanup pipeline and exit handler
  trap "cleanupFunction" EXIT INT TERM QUIT HUP
  [ -z "${ZOPEN_CLEANUP_PIPE}" ] \
  && [ ! -p "${ZOPEN_CLEANUP_PIPE}" ] \
  && ZOPEN_CLEANUP_PIPE=$(mktempfile "clean" "pipe") \
  && mkfifo "${ZOPEN_CLEANUP_PIPE}" \
  && chtag -tc 819 "${ZOPEN_CLEANUP_PIPE}" \
  && export ZOPEN_CLEANUP_PIPE

  addCleanupTrapCmd "stty echo 2>/dev/null" # set this as a default to ensure line visibility!
  defineEnvironment
  defineANSI
  if [ -z "${ZOPEN_DONT_PROCESS_CONFIG}" ]; then
    processConfig
  fi

  ZOPEN_JSON_CACHE_URL="https://zosopentools.github.io/meta/api/zopen_releases.json"
}

zopenInitialize
