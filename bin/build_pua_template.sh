#!/bin/bash
# Filename: build_pua.sh
#
# Builds out a reference PUA deployment on a BIG-IP running TMOS 13.1.0.x
#
# Bill Church - bill@f5.com
#
scriptversion="1.0.26-rc1"

# If you want to run this in non-interactive mode, download, modify and place pua_config.sh in the
# same folder as this script on the BIG-IP.
#
# For more information, see https://github.com/billchurch/f5-pua

shopt -s nocasematch

scriptname=$(basename $0)
bigipver=$(cat /etc/issue | grep -i BIG-IP | awk '{print $2}')
workingdir=$(mktemp -d -t pua.XXXXXXXXXX)
ucsbackupfile=$(mktemp -u before-pua-$scriptversion-XXXX)
websshfname=BIG-IP-13.1.0.8-ILX-WebSSH2-current.tgz
websshilxver=0.2.7
websshilxname=WebSSH2-$websshilxver
websshilxplugin=WebSSH_plugin
ephemeralfname=BIG-IP-ILX-ephemeral_auth-current.tgz
ephemeralilxver=0.2.17
ephemeralilxname=ephemeral_auth-$ephemeralilxver
ephemeralilxplugin=ephemeral_auth_plugin
samplecafname=ca.pua.lab.cer
apmpolicyfname=profile-pua_webtop_policy.conf.tar.gz
apmpolicydisplayname="sample_pua_policy"
ilxarchivedir=/var/ilx/workspaces/Common/archive
provlevel=nominal
modulesrequired="apm ilx"
configfile="pua_config.sh"
runhelp=false
runupgrade=false
checkonly=false
nobackup=false
disabletest=false
cols=$(tput cols)

#colors
fgLtRed=$(tput bold;tput setaf 1)
fgLtGrn=$(tput bold;tput setaf 2)
fgLtYel=$(tput bold;tput setaf 3)
fgLtBlu=$(tput bold;tput setaf 4)
fgLtMag=$(tput bold;tput setaf 5)
fgLtCya=$(tput bold;tput setaf 6)
fgLtWhi=$(tput bold;tput setaf 7)
fgLtGry=$(tput bold;tput setaf 8)

echo ${fgLtWhi}
clear

# get cli params...
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
  -h|--help)
  runhelp=true
  shift
  ;;
  -u|--upgrade)
  runupgrade=true
  shift
  ;;
  -c|--checkonly)
  checkonly=true
  shift
  ;;
  -n|--nobackup)
  nobackup=true
  shift
  ;;
  -d|--disabletest)
  disabletest=true
  shift

  ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

echoNotice () { echo; echo -n "$@"; }

cleanup () {
  # runs on EXIT or CTRL-C
  echo
  echo "Cleaning up..."
  echo "${fgLtWhi}"
  rm -rf "$workingdir"
}
trap cleanup EXIT

# dont try to figure it out, just ask bill@f5.com
defaultip=
mgmtip=$(ip addr show mgmt | grep -oP 'inet \K(?:(?:2[0-5]?[0-5]?|[01]?[0-9][0-9]?)\.){3}(?:2[0-5]?[0-5]?|[01]?[0-9][0-9]?)')

read status </var/prompt/ps1

# This is a round about way to get the directory that the script was executed from...
pushd . > /dev/null
script_path="${BASH_SOURCE[0]}";
while([ -h "${script_path}" ]); do
    cd "`dirname "${script_path}"`"
    script_path="$(readlink "`basename "${script_path}"`")";
done
cd "`dirname "${script_path}"`" > /dev/null
script_path="`pwd`";
popd  > /dev/null

echo "${script_path}/${scriptname} - v$scriptversion"

# Reading the config file, that's your chance to change or customize any variables
# set above...

if [[ -f "${script_path}/$configfile" ]]; then
  echo "Reading config from ${script_path}/$configfile..."
  source ${script_path}/$configfile
fi

function run_help() {
fold -s -w $cols <<HELPFILE | less --RAW-CONTROL-CHARS -X -F -K -E
${fgLtWhi}
${fgLtYel}F5 Privileged User Authentication Install Script v${scriptversion}${fgLtWhi}
========================================================

This script will configure a reference implementation of the F5 Privileged User Authentication solution.

Please see ${fgLtBlu}${ulStart}https://github.com/billchurch/f5-pua${ulStop}${fgLtWhi} for more information

${fgLtYel}Usage${fgLtWhi}
=====

        --help | -h - This notice
      --update | -u - Update existing installation
   --checkonly | -c - Check installed versions against this package
    --nobackup | -n - Does not perform UCS backup
 --disabletest | -d - Do not perform host IP validation (ping)

HELPFILE
echo
}

if [ "$runhelp" == "true" ]; then
  run_help
  exit
fi

function version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

function check_version() {
  packageversion=$1
  checkversion=$2
  installedver=
  # Get current version of workspace(s) from active plugin(s)
  echo
  isinstalled=$(tmsh list ilx plugin one-line | grep -i $checkversion | grep -oP 'staged-directory \K.*[\w]' | wc -l)
  if [[ ("$isinstalled" == 0) ]]; then
      echo "Package ${fgLtCya}$checkversion${fgLtWhi} is ${fgLtRed}NOT${fgLtWhi} installed"
      echo
      echo "Can't upgrade, aborting..."
      exit 255
  fi
  for directory in `tmsh list ilx plugin one-line | grep -i $checkversion | grep -oP 'staged-directory \K.*[\w]'`
    do installedver=$(jq -r ".version" $directory/extensions/$checkversion/package.json)
    echo -n "Package version of ${fgLtCya}$checkversion${fgLtWhi} ($packageversion) is "
    if version_gt $packageversion $installedver; then
      echo -n "${fgLtRed}greater than${fgLtWhi} "
      packagenewer=true
    else
      echo -n "${fgLtGrn}less than or equal to${fgLtWhi} "
      packagenewer=false
    fi
    echo "installed version ($installedver)."
  done
}

if [[ ("$status" != "Active") ]]; then
  tput bel;tput bel;tput bel;tput bel
  echo
  echo "Your BIG-IP system does not appear to be in a consistent state, status reports: $status"
  echo
  echo "Please correct the condition and try running this script again."
  echo
  exit 255
fi

archive_location=$(awk '/^__PUA_ARCHIVE__/ {print NR + 1; exit 0 ; }' ${script_path}/${scriptname})

displayIntroduction () {
fold -s -w $cols <<INTRODUCTION | less --RAW-CONTROL-CHARS -X -F -K -E
${fgLtWhi}
${fgLtYel}F5 Privileged User Authentication Install Script v${scriptversion}${fgLtWhi}
========================================================

This script will configure a reference implementation of the F5 Privileged User Authentication solution. The only requirements are a running and licensed system ("Active"), initial configuration complete (licensed, VLANs, self IPs), and preferably already provisioned for LTM+APM+ILX. The script will check for and can enable it for you if you wish.

You will be prompted for IP addresses for 5 services:

1. WebSSH Proxy - This proxy is ultimately called by the APM web top. This IP may be shared with other IPs on the BIG-IP system if the protocol or port (udp/2222) It’s also important to note that SNAT may not be used on this virtual server. (webssh_proxy)

2. RADIUS Proxy – This runs the RADIUS Ephemeral Authentication Service. This IP may be shared with other IPs on the BIG-IP system if the protocol or port (udp/1812) do not conflict. (radius_proxy)

3. LDAP Proxy – This runs the LDAP Ephemeral Authentication Service. This IP may be shared with other IPs on the BIG-IP system if the protocol or port (tcp/389) do not conflict. (ldap_proxy)

4. LDAPS Proxy – This runs the LDAPS (ssl) Ephemeral Authentication Service. This IP may be shared with other IPs on the BIG-IP system if the protocol or port (tcp/636) do not conflict. (ldaps_proxy)

5. Web top – This runs the LDAP Ephemeral Authentication Service. This IP may be shared with other IPs on the BIG-IP system if the protocol or port (tcp/443) do not conflict. By default SNAT is disabled for this vs as the WebSSH proxy may not interoperate with SNAT. If you change this option be sure to institute some sort of selective disable option (iRule) when connecting to the webssh_proxy as a portal resource.

WebSSH, LDAPS, and web top will all be initially configured with a default client-ssl profile, after testing this should be changed to use a legitimate certificate.

A blank APM policy is created and attached to the web top vs “pua_webtop”, this policy will need to be built out for the pua_webtop service to operate correctly.

${fgLtYel}RADIUS Testing${fgLtWhi}
==============

The BIG-IP administrative interface can be configured to authenticate against itself for testing. This will allow “admin” and anyone using the test account “testuser” with ANY password to authenticate as a guest to the GUI or SSH. If you enable this option, instructions will be provided at the end of this script for testing
INTRODUCTION
echo
echo "Press any key to continue, or CTRL-C to cancel."
read -n1 NUL
echo
}

# checks the output of a command to get the status and report/handle failure
checkoutput() {
  if [ $result -eq 0 ]; then
    # success
    echo "${fgLtGrn}[OK]${fgLtWhi}"
    return
  else
    # failure
    tput bel;tput bel;tput bel;tput bel
    echo "${fgLtRed}[FAILED]${fgLtWhi}"
    echo -e "\n\n"
    echo "Previous command failed in ${script_path}/${scriptname} with error level: ${result} on line: $prevline:"
    echo
    sed "${prevline}q;d" ${script_path}/${scriptname} | tr -d '[:space:]'
    echo -e "\n\n"
    echo "STDOUT/STDERR:"
    echo ${output}
    exit 255
  fi
}

# get an IP address, verify input, and ping it to do a rudimentary
# check to see if its being used
getvip() {
  yesno="n"
  while [ "$yesno" == "n" ]
    do
    echo
    if [[ ! ("$noninteractive" == "y") || ("$reprompt" == "y") ]]; then
      if [ "$defaultip" == "" ]; then
        echo "Type the IP address of your $servicename service virtual server"
        echo -n "and press ENTER: "
      else
        echo "Type the IP address of your $servicename service virtual server"
        echo -n -e "and press ENTER [${fgLtCya}$defaultip${fgLtWhi}]: "
      fi
      read servicenamevip
      servicenamevip="$(echo -e "${servicenamevip}" | tr -d '[:space:]')"
      if [[ ("$servicenamevip" == "") && ("$defaultip" != "") ]]; then
        servicenamevip=$defaultip
      fi
      read -t 1 -n 10000 discard
      echo
      echo -n -e "You typed ${fgLtCya}$servicenamevip${fgLtWhi}, is that correct (Y/n)? "
      read -n1 yesno
      reprompt="n"
    else
      echo "$servicename = ${fgLtCya}$servicenamevip${fgLtWhi}"
      yesno="y"
    fi
    # MC - ADD Non Interactive Bypass
    if [[ ("$yesno" != "n") && ("$servicenamevip" != "$checkedip") && ("$noninteractive" == "n")]]; then
      echo
      echo -n "Checking IP... "
      output=$(ping -c 1 $servicenamevip 2>&1)
      if [[ $? -eq 0 ]]; then
        tput bel;tput bel;tput bel;tput bel;
        echo "${fgLtRed}[FAILED]${fgLtWhi}"
        echo
        echo "${fgLtRed}ERROR:${fgLtWhi} IP address $servicenamevip appears to be taken by another host on the network already."
        echo
        arp -a $servicenamevip
        echo
        echo "Pick a different host or investigate the issue."
        echo
        yesno="n"
        reprompt="y"
      else
        echo "${fgLtGrn}[OK]${fgLtWhi}"
        checkedip=$servicenamevip
      fi
    fi
  done
  return
}

# Check required files and see if they've downloaded successfully
checkFile() {
  fname=$1
  echo
  echo -n "Checking for $fname... "
  if [ ! -f $fname ]; then
    echo "${fgLtRed}[FAILED]${fgLtWhi}"
    echo "$fname does not exist. Halting."
    exit 255
  else
    echo "${fgLtGrn}[OK]${fgLtWhi}"
  fi
  echo
  echo -n "Hash check for $fname "
  output=$((sha256sum -c $fname.sha256) 2>&1)
  result="$?" 2>&1
  if [ $? -gt 0 ]; then
    echo "${fgLtRed}[FAILED]${fgLtWhi}"
    echo "SHA256 checksum failed. Halting."
    echo "Output from command: $output"
    exit 255
  else
    echo "${fgLtGrn}[OK]${fgLtWhi}"
  fi
}

# check and see that the appropratie BIG-IP modules are provisioned
# and offer to provision them if not
checkProvision() {
  missingmod=""
  echo
  echo "Checking modules are provisioned."
  echo
  for i in $modulesrequired; do
    echo -n "Checking $i... "
    output=$(tmsh list sys provision $i one-line|awk '{print $6}')
    if [ "$output" == "" ]; then
    echo "${fgLtRed}[FAILED]${fgLtWhi}"
      echo
      missingmod+="$i "
    else
      echo "${fgLtGrn}[OK]${fgLtWhi}"
    fi
  done
  if [ "$missingmod" == "" ]; then
    echo
    echo "SUCCESS: All modules provisioned."
  else
    echo
    echo "${fgLtYel}Module Provisioning${fgLtWhi}"
    echo "${fgLtYel}===================${fgLtWhi}"
    echo
    echo "Modules: $missingmod are not provisioned."
    tput bel;tput bel
    echo
    echo "$missingmod may be provisioned to the level of $provlevel."
    echo
    echo "Provisioning modules could result in service interruption and a reboot may be required."
    echo
    echo -n "Would you like to provision them (Y/n)? "
    read -n1 yesno
    if [ "$yesno" != "n" ]; then
      echo
      echo -n "Provisioning "
      echo 'proc script::run {} {' > $workingdir/provision.tcl
      echo '  tmsh::begin_transaction' >> $workingdir/provision.tcl
      for i in $missingmod; do
        echo "  tmsh::modify /sys provision $i level $provlevel" >> $workingdir/provision.tcl
      done
      echo '  tmsh::commit_transaction' >> $workingdir/provision.tcl
      echo '}' >> $workingdir/provision.tcl
      output=$((tmsh run cli script file $workingdir/provision.tcl)  2>&1)
      result="$?" 2>&1
      prevline=$(($LINENO-2))
      checkoutput
      sleep 10
      echo
      echo -n "Saving config "
      output=$((tmsh save /sys config) 2>&1)
      result="$?" 2>&1
      prevline=$(($LINENO-2))
      checkoutput
      status=
      echo
      echo -n "Waiting for provisioning to quiesce "
      while [[ "$status" != "Active" ]]; do
        sleep 1
        echo -n .
        read status </var/prompt/ps1
        if [ "$status" == "REBOOT REQUIRED" ]; then
          tput bel;tput bel;tput bel;tput bel
          echo
          echo "${fgLtRed}REBOOT REQUIRED${fgLtWhi}"
          echo
          echo "Due to provisioning requirements, a reboot of this sytems is required."
          echo
          echo "Please reboot the system and re-run this script to continue."
          echo
          exit 255
        fi
      done
      echo "${fgLtGrn}[OK]${fgLtWhi}"
    else
      tput bel;tput bel;tput bel;tput bel
      echo -e "\n\n"
      echo "${fgLtRed}ERROR:${fgLtWhi} Refusing to run until modules are provisioned. Please provision at least APM and ILX"
      echo "and run script again."
      echo
      exit 255
    fi
  fi
}

# Extract the self-contained support files (ILX plugins, policies certificates, etc...)
extractArchive () {
  echo
  echo -n "Extracting archive "
  output=$((/usr/bin/tail -n+$archive_location ${script_path}/${scriptname} | /usr/bin/base64 -d | /bin/tar xzv -C $workingdir) 2>&1)
  result="$?" 2>&1
  prevline=$(($LINENO-2))
  checkoutput
  return
}

# are we running in interactive mode or automated?
checkInteractive () {
  if [[ "$noninteractive" == "y" ]]; then
    if [[ ("$webssh2vip" = "") || ("$radiusvip" == "") || ("$ldapvip" == "") || ("$ldapsvip" == "") || ("$webtopvip" == "") ]]; then
      echo
      echo "${fgLtRed}ERROR${fgLtWhi}"
      echo
      echo "Non-interactive mode specified with empty variables. For non interactive mode all variables must be specified." | fold -s -w $cols
      exit 255
    else
      echo
      echo "${fgLtGrn}noninteractive is GO... Buckle up...${fgLtWhi}"
    fi
  else
    echo
    echo "Interactive"
  fi
}

# Alert on BIG-IP version
checkVer () {
  if [[ "$bigipver" != "13.1.1.2" ]]; then
    echo
    echo "${fgLtRed}WARNING${fgLtWhi}"
    echo
    echo "This script has only been tested with BIG-IP v13.1.1.2."
    echo
    echo "As long as version is greater that tested this should be fine."
    echo
    echo "${fgLtRed}Proceed at your own risk${fgLtWhi}"
    echo
  fi
}

# Enable BIG-IP RADIUS auth against itself?
radiusTestOption () {
  if [[ ("$radiusconfig" == "") ]]; then
    fold -s -w $cols <<RADIUSINFO | less --RAW-CONTROL-CHARS -X -F -K -
${fgLtWhi}
${fgLtYel}RADIUS Testing Option${fgLtWhi}
=====================

You can automatcially configure the BIG-IP for RADIUS authentication against itself for testing purposes. If this is running on a production system, this may impact access and is not recommended. This option is recommended for lab and demo use only.

RADIUSINFO

    tput bel;tput bel
    radiusconfig="n"
    echo -n "Do you want to configure this BIG-IP to authenticate against itself for testing purposes (Y/n)? "
    read -n1 yesno
    if [ "$yesno" != "n" ]; then
      yesno=n
      echo
      echo
      echo -n "Are you really sure!? (Y/n)? "
      read -n1 radiusconfig
      echo
    fi
  fi
  if [[ ("${radiusconfig}" != "n") ]]; then
    echo
    echo -n "Modifying BIG-IP for RADIUS authentication against itself... "
    cat >$workingdir/radius.tcl <<RADIUS
proc script::run {} {
  tmsh::begin_transaction
  tmsh::create /auth radius-server system_auth_name1 secret radius_secret server $radiusvip
  tmsh::create /auth radius system-auth { servers add { system_auth_name1 } }
  tmsh::modify /auth remote-user default-role guest remote-console-access tmsh
  tmsh::modify /auth source type radius
  tmsh::commit_transaction
}
RADIUS
    output=$((tmsh run cli script file $workingdir/radius.tcl) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
    if [[ !("${disabletest}" == "true") ]]; then
      echo
      fold -s -w $cols <<RADIUSSUMMARY | less --RAW-CONTROL-CHARS -X -F -K -
You can test WebSSH2 and Ephemeral authentication without APM configuration now by browsing to:
${fgLtWhi}
  ${fgLtYel}https://$webssh2vip:2222/ssh/host/$mgmtip${fgLtWhi}

  username: testuser
  password: anypassword

This will allow anyone using the username testuser to log in with any password as a guest
RADIUSSUMMARY
    fi
  fi

  if [[ ("${disabletest}" == "true") ]]; then
    echo
    fold -s -w $cols <<SSHTEST | less --RAW-CONTROL-CHARS -X -F -K -
You can test WebSSH2 and Ephemeral authentication without APM configuration now by browsing to:
${fgLtWhi}
  ${fgLtYel}https://$webssh2vip:2222/ssh/host/$mgmtip${fgLtWhi}

  username: <valid BIG-IP user>
  password: <valid password>

This will allow anyone with a valid account and terminal to log into the BIG-IP over ssh. Note: by
default "admin" does not have ssh access.
SSHTEST
  fi

}

# setup clientssl profile
clientsslProfile () {
  if [[ -f "${script_path}/$samplecafname" ]]; then
    capathandfile="${script_path}/$samplecafname"
    customca="y"
  else
    capathandfile="${workingdir}/${samplecafname}"
  fi
  if [[ !("$sampleca" == "y") ]]; then
    echo
    echo "${fgLtYel}Sample Certificate Authority${fgLtWhi}"
    echo "============================"
    echo
    echo "A sample CA is available for testing. This should be implemented on non-production systems only."
    echo
    echo -n "Would you like to install a sample CA for testing (Y/n)? "
    read -n1 sampleca
  fi
  echo
  if [[ ("$sampleca" == "y") ]]; then
    if [[ !("$customca" == "y") ]]; then
      checkFile $samplecafname
    fi
    echo -n "Installing CA file ${fgLtCya}${samplecafname}${fgLtWhi} "
    output=$((tmsh install sys crypto cert ${samplecafname} from-local-file ${capathandfile} cert-validators none) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
    echo
    echo -n "Creating pua_webtop-clientssl profile with CA ${fgLtCya}${samplecafname}${fgLtWhi} "
    output=$((tmsh create ltm profile client-ssl pua_webtop-clientssl defaults-from clientssl handshake-timeout 120 ca-file ${samplecafname}.crt client-cert-ca ${samplecafname}.crt) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
  else
    echo -n "Creating pua_webtop-clientssl profile "
    output=$((tmsh create ltm profile client-ssl pua_webtop-clientssl defaults-from clientssl) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
  fi
}

# import apm policy
createAPMpolicy () {
  if [[ -f "${script_path}/$apmpolicyfname" ]]; then
    policypathandfile="${script_path}/$apmpolicyfname"
    custompolicy="y"
  else
    policypathandfile="${workingdir}/${apmpolicyfname}"
  fi
  if [[ !("$custompolicy" == "y") ]]; then
    checkFile $apmpolicyfname
  fi
    echo
    echo -n "Importing APM sample profile ${fgLtCya}${apmpolicyfname}${fgLtWhi} "
    output=$((ng_import ${policypathandfile} ${apmpolicydisplayname} ) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
}

# the commands. this is where things start to happen
checkInteractive

[[ ! ("$noninteractive" == "y") && ( ! ("$checkonly" == "true") && ! ("$runupgrade" == "true") ) ]] && displayIntroduction

checkVer

echoNotice "Preparing environment... "
output=$((mkdir -p $workingdir) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Changing to $workingdir... "
cd $workingdir
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

if [[ "$archive_location" != "" ]]; then
  extractArchive
fi

if [[ ("$checkonly" == "false") ]]; then 
  nobackup=true
fi

if [[ ( "$nobackup" == "false" ) ]]; then
  echo "nobackup: $nobackup"
  echoNotice "Creating UCS archive ${fgLtCya}$ucsbackupfile${fgLtWhi}, this will take a moment... "
  output=$((tmsh save sys ucs $ucsbackupfile) 2>&1)
  result="$?" 2>&1
  prevline=$(($LINENO-2))
  checkoutput
fi

echoNotice "Adding ILX archive directory "
output=$((mkdir -p $ilxarchivedir) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

checkProvision

checkFile $websshfname

checkFile $ephemeralfname

if [ "$runupgrade" == "true" ] || [ "$checkonly" == "true" ]; then

  echo
  echo "Checking versions..."
  check_version $websshilxver webssh2
  if [ "$packagenewer" == "true" ]; then upgradewebssh2=true; fi
  check_version $ephemeralilxver ephemeral_auth
  if [ "$packagenewer" == "true" ]; then upgradeephemeralauth=true; fi


  if [ "$checkonly" == "true" ]; then exit 255; fi

  echo
  echo "Doing the upgrade..."

  if [ "$upgradewebssh2" == "true" ]; then
    echoNotice "Placing $websshfname in $ilxarchivedir... "
    output=$((mv -f $workingdir/$websshfname $ilxarchivedir/$websshfname) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput

    echoNotice "Importing WebSSH2 Workspace... "
    output=$((tmsh create ilx workspace $websshilxname from-archive $websshfname) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput

    echoNotice "Modifying WebSSH2 Plugin... "
    output=$((tmsh modify ilx plugin $websshilxplugin from-workspace $websshilxname extensions { webssh2 { concurrency-mode single ilx-logging enabled  } }) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
  fi

  if [ "$upgradeephemeralauth" == "true" ]; then
    echoNotice "Placing $ephemeralfname in $ilxarchivedir... "
    output=$((mv -f $workingdir/$ephemeralfname $ilxarchivedir/$ephemeralfname) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput

    echoNotice "Importing Ephemeral Authentication Workspace... "
    output=$((tmsh create ilx workspace $ephemeralilxname from-archive $ephemeralfname) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput

    echoNotice "Modifying Ephemeral Authentication Workspace... "
    output=$((tmsh modify ilx workspace $ephemeralilxname node-version 6.9.1) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput

    echoNotice "Modifying Ephemeral Authentication Plugin... "
    output=$((tmsh modify ilx plugin $ephemeralilxplugin from-workspace $ephemeralilxname extensions { ephemeral_auth { ilx-logging enabled } }) 2>&1)
    result="$?" 2>&1
    prevline=$(($LINENO-2))
    checkoutput
  fi
  echo
  echo "Upgrade Complete."
  echo
  echo cp /root/.pua-version /root/.pua-previous
  echo $scriptversion > /root/.pua-version
  echo $scriptversion > /root/.pua-upgrade

  exit 0

fi


servicename=WebSSH2
servicenamevip=$webssh2vip
[[ !("$servicenamevip" == "") ]] && defaultip=$servicenamevip
getvip
webssh2vip="$servicenamevip"
defaultip=$servicenamevip

servicename=RADIUS
servicenamevip=$radiusvip
[[ !("$servicenamevip" == "") ]] && defaultip=$servicenamevip
getvip
radiusvip="$servicenamevip"
defaultip=$servicenamevip

servicename=LDAP
servicenamevip=$ldapvip
[[ !("$servicenamevip" == "") ]] && defaultip=$servicenamevip
getvip
ldapvip="$servicenamevip"
defaultip=$servicenamevip

servicename=LDAPS
servicenamevip=$ldapsvip
[[ !("$servicenamevip" == "") ]] && defaultip=$servicenamevip
getvip
ldapsvip="$servicenamevip"
defaultip=$servicenamevip

servicename=Webtop
servicenamevip=$webtopvip
[[ !("$servicenamevip" == "") ]] && defaultip=$servicenamevip
getvip
webtopvip="$servicenamevip"
defaultip=$servicenamevip

clientsslProfile

echoNotice "Placing $websshfname in $ilxarchivedir... "
output=$((mv -f $workingdir/$websshfname $ilxarchivedir/$websshfname) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Placing $ephemeralfname in $ilxarchivedir... "
output=$((mv -f $workingdir/$ephemeralfname $ilxarchivedir/$ephemeralfname) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating ephemeral_config data group... "
if [[ ("${disabletest}" == "true") ]]; then
  output=$((tmsh create ltm data-group internal ephemeral_config { records add { DEBUG { data 0 } DEBUG_PASSWORD { data 0 } RADIUS_SECRET { data radius_secret } RADIUS_TESTMODE { data 0 } ROTATE { data 0 } pwrulesLen { data 8 } pwrulesLwrCaseMin { data 1 } pwrulesNumbersMin { data 1 } pwrulesPunctuationMin { data 1 } pwrulesUpCaseMin { data 1 } } type string }) 2>&1)
  result="$?" 2>&1
  prevline=$(($LINENO-2))
  checkoutput
else
  output=$((tmsh create ltm data-group internal ephemeral_config { records add { DEBUG { data 2 } DEBUG_PASSWORD { data 1 } RADIUS_SECRET { data radius_secret } RADIUS_TESTMODE { data 1 } RADIUS_TESTUSER { data testuser } ROTATE { data 0 } pwrulesLen { data 8 } pwrulesLwrCaseMin { data 1 } pwrulesNumbersMin { data 1 } pwrulesPunctuationMin { data 1 } pwrulesUpCaseMin { data 1 } } type string }) 2>&1)
  result="$?" 2>&1
  prevline=$(($LINENO-2))
  checkoutput
fi

echoNotice "Creating ephemeral_LDAP_Bypass data group... "
output=$((tmsh create ltm data-group internal ephemeral_LDAP_Bypass { records add { "cn=f5 service account,cn=users,dc=mydomain,dc=local" { } cn=administrator,cn=users,dc=mydomain,dc=local { } cn=proxyuser,cn=users,dc=mydomain,dc=local { } } type string }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating ephemeral_RADIUS_Bypass data group... "
output=$((tmsh create ltm data-group internal ephemeral_RADIUS_Bypass { type string }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating ephemeral_radprox_host_groups data group... "
output=$((tmsh create ltm data-group internal ephemeral_radprox_host_groups { type string }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating ephemeral_radprox_radius_attributes data group... "
output=$((tmsh create ltm data-group internal ephemeral_radprox_radius_attributes { records add { BLUECOAT { data "[['Service-Type', <<<VALUE>>>]]" } CISCO { data "[['Vendor-Specific', 9, [['Cisco-AVPair', 'shell:priv-lvl=<<<VALUE>>>']]]]" } DEFAULT { data "[['Vendor-Specific', 9, [['Cisco-AVPair', 'shell:priv-lvl=<<<VALUE>>>']]]]" } F5 { data "[['Vendor-Specific', 3375, [['F5-LTM-User-Role, <<<VALUE>>>]]]]" } PALOALTO { data "[['Vendor-Specific', 25461, [['PaloAlto-Admin-Role', <<<VALUE>>>]]]]" } } type string }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating ephemeral_radprox_radius_client data group... "
output=$((tmsh create ltm data-group internal ephemeral_radprox_radius_client { type string }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Importing WebSSH2 Workspace... "
output=$((tmsh create ilx workspace $websshilxname from-archive $websshfname) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Importing Ephemeral Authentication Workspace... "
output=$((tmsh create ilx workspace $ephemeralilxname from-archive $ephemeralfname) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Modifying Ephemeral Authentication Workspace... "
output=$((tmsh modify ilx workspace $ephemeralilxname node-version 6.9.1) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating WebSSH2 Plugin... "
output=$((tmsh create ilx plugin $websshilxplugin from-workspace $websshilxname extensions { webssh2 { concurrency-mode single ilx-logging enabled  } }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating WEBSSH Proxy Service Virtual Server... "
output=$((tmsh create ltm virtual webssh_proxy { destination $webssh2vip:2222 ip-protocol tcp mask 255.255.255.255 profiles add { clientssl-insecure-compatible { context clientside } f5-tcp-lan { } }  rules { WebSSH_plugin/webssh2_node } source 0.0.0.0/0 translate-address enabled translate-port enabled }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating Ephemeral Authentication Plugin... "
output=$((tmsh create ilx plugin $ephemeralilxplugin from-workspace $ephemeralilxname extensions { ephemeral_auth { ilx-logging enabled } }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating RADIUS Proxy Service Virtual Server... "
output=$((tmsh create ltm virtual radius_proxy { destination $radiusvip:1812 ip-protocol udp mask 255.255.255.255 profiles add { udp { } } source-address-translation { type automap } source 0.0.0.0/0 rules { $ephemeralilxplugin/radius_proxy }}) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echo
echo -n "Creating LDAP Proxy Service Virtual Server... "
output=$((tmsh create ltm virtual ldap_proxy { destination $ldapvip:389 ip-protocol tcp mask 255.255.255.255 profiles add { f5-tcp-lan { } } source-address-translation { type automap } source 0.0.0.0/0 rules { $ephemeralilxplugin/ldap_proxy }}) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating LDAPS (ssl) Proxy Service Virtual Server... "
output=$((tmsh create ltm virtual ldaps_proxy { destination $ldapsvip:636 ip-protocol tcp mask 255.255.255.255 profiles add { f5-tcp-lan { } clientssl { context clientside } serverssl-insecure-compatible { context serverside } } source-address-translation { type automap } source 0.0.0.0/0 rules { $ephemeralilxplugin/ldap_proxy_ssl }}) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating APM connectivity profile... "
output=$((tmsh create /apm profile connectivity pua-connectivity defaults-from connectivity) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

createAPMpolicy

echoNotice "Modifying pua APM Portal Resource..."
output=$((tmsh modify apm resource portal-access sample_pua_policy-webssh_portal application-uri https://${webssh2vip}:2222/ssh/host/${mgmtip} items modify { item { subnet ${webssh2vip}/32 } }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Applying pua APM Policy..."
output=$((tmsh modify /apm profile access /Common/${apmpolicydisplayname} generation-action increment) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echoNotice "Creating Webtop Virtual Server... "
output=$((tmsh create ltm virtual pua_webtop { destination $webtopvip:443 ip-protocol tcp mask 255.255.255.255 profiles add { http { } ppp { } pua-connectivity pua_webtop-clientssl { context clientside } rba { } rewrite-portal { } ${apmpolicydisplayname} { } serverssl-insecure-compatible { context serverside } f5-tcp-lan { } httpcompression { } websso { } } rules { $ephemeralilxplugin/APM_ephemeral_auth } source 0.0.0.0/0 }) 2>&1)
#output=$((tmsh create ltm virtual pua_webtop { destination $webtopvip:443 ip-protocol tcp mask 255.255.255.255 profiles add { http rewrite-portal tcp { } pua-connectivity { context clientside } pua_webtop-clientssl { context clientside } serverssl-insecure-compatible { context serverside } } rules { $ephemeralilxplugin/APM_ephemeral_auth } source 0.0.0.0/0 }) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

radiusTestOption

echoNotice "Saving config... "
output=$((tmsh save /sys config) 2>&1)
result="$?" 2>&1
prevline=$(($LINENO-2))
checkoutput

echo
    fold -s -w $cols <<FINALSUMMARY | less --RAW-CONTROL-CHARS -X -F -K -
You can test your new APM webtop now by browsing to:
${fgLtWhi}
  ${fgLtYel}https://$webtopvip${fgLtWhi}

  username: <any>
  password: <any>

This will let anyone in with any policy. The next step after testing would be to add access control through AD, MFA, or some other method.

If the RADIUS testing option was enabled, any username will log in using Ephemeral Authentication.

FINALSUMMARY

echo "Task complete."
echo
echo "Now go build an APM policy for PUA!"
echo $scriptversion > /root/.pua-version

exit 0
