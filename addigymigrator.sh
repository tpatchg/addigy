#!/bin/bash

cat << "EOF" > /tmp/agent_migrator.sh
# Addigy Migrator Script

######################################################################################################
# VARIABLES ##########################################################################################
######################################################################################################

#Get Addigy MDM Link from Add Devices > Select a Policy > Target Policy > Install via MDM > Device Enrollment > Copy Link
MDMLink='https://mdm-prod.addigy.com/mdm/enroll/someuuid'

# Update these values from other MDM Environment -- Refer to Guide
apiURL='https://as157.awmdm.com/API'

apiUser='RestUser'
apiPass='SomePassword!'

apiKey='fake4Iy7aLKFq9V9aWQfHIakey'

# Choose to remove device from previous MDM or leave for records. Values: yes or empty
deleteFromMDM='yes'

# If all devices are in ADE, set to yes.
allADE='yes'
# If some devices are in ADE, export device list from ABM/ASM for devices expected to migrate.  Otherwise leave blank.
csvPath='/Library/Addigy/ansible/packages/Migrator Script (1.0)/ADEdevices.csv'

# If devices are connected to WiFi that is configured by mdm profile, provide temporary WiFi connection.  Will check if device is connected to managedSSID.
# If not then leave these blank
managedSSID='MDM WiFi'
tempSSID='temp-wifi'
tempPSK='temp-password'

# DEPNotify Welcome Title ###
MAIN_TITLE="Addigy Migrator"

# DEPNotify Welcome Window Text ###
MAIN_TEXT="Please wait while your computer is migrated to the new system. This will take a few minutes."

# DEPNotify Enroll instructions based on OS
newerInstallDirections="This device requires user profile installation. Please double-click the new profile, then click 'Enroll' inside the System Settings Pane"
olderInstallDirections="This device requires user profile installation. Please click 'Install' inside the System Preferences Pane"
DEPInstallDirections="Please click on the Device Enrollment notification to finish MDM profile installation.  Make sure notifications are not silenced with DND or Focus."

### File Locations
DEP_N_DEBUG="/var/tmp/debug_depnotify.log"
DEP_N_APP="/Applications/Utilities/DEPNotify.app"
DEP_N_LOG="/var/tmp/depnotify.log"

### Device lookups
serialNumber="$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $4}')"

######################################################################################################
# Begin Declaring Functions ##########################################################################
######################################################################################################

function joinTemporaryWiFi() {
  connectionType=$(networksetup -listallhardwareports | grep -C1 "$(route get default | grep interface | awk '{print $2}')" | awk -F ': ' '/Hardware Port/ {print $NF}')
  echo "Connected via $connectionType" >>"$DEP_N_LOG"
  if [[ ${connectionType} == "Wi-Fi" ]]; then
    currentSSID=$(/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport -I | awk -F' SSID: ' '/ SSID: / {print $2}')
    if [[ "$currentSSID" == "$managedSSID" ]]; then
      echo "Joining Temporary WiFi to keep connectivity when removing managed WiFi." >>"$DEP_N_LOG"
      echo "Status: Temporarily connecting to $tempSSID WiFi..." >>"$DEP_N_LOG"
      adapter=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')
      joinedTemp=true
      wifiCount=0
      sleep 1
      while [[ $currentSSID != "$tempSSID" ]]; do
        networksetup -setairportnetwork "${adapter}" "${tempSSID}" "${tempPSK}"
        networksetup -addpreferredwirelessnetworkatindex "${adapter}" "${tempSSID}" 0 WPA2 "${tempPSK}"
        sleep 2
        currentSSID=$(/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport -I | awk -F' SSID: ' '/ SSID: / {print $2}')
        ((wifiCount++))
        echo "Status: Reconnecting to WiFi network... Attempt ${wifiCount}" >>"$DEP_N_LOG"
      done
      sleep 5
    fi
  fi
}

function disconnectTemporaryWiFi() {
  if [ "$joinedTemp" = true ]; then
    if [[ "$currentSSID" == "$tempSSID" ]]; then
      echo "Warning: Device still on temporary Wi-Fi, managed Wi-Fi profile not recieved yet." >>"$DEP_N_LOG"
      echo "Warning: Remove temporary SSID from preferred networks later." >>"$DEP_N_LOG"
    else
      adapter=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')
      echo "Removing temporary SSID from preferred networks." >>"$DEP_N_LOG"
      networksetup -removepreferredwirelessnetwork "${adapter}" "${tempSSID}"
      echo "Status: Restarting WiFi" >>"$DEP_N_LOG"
      networksetup -setairportpower "${adapter}" off
      networksetup -setairportpower "${adapter}" on
    fi
  fi
}

function installADE() {
    echo "ADE Device Identified. Running profiles command." >>"$DEP_N_LOG"
    sudo profiles renew -type enrollment
    echo "Command: MainText: $DEPInstallDirections" >>"$DEP_N_LOG"
    echo "Waiting for ADE profile to be installed or for timeout" >>"$DEP_N_LOG"
    sleep 15
    isApproved=$(profiles status -type enrollment | grep -o "User Approved")
    counter=0
    while [ -z "$isApproved" ] && [ "$counter" -lt "13" ]; do
      ((counter++))
      echo "Trying profiles renew again." >>"$DEP_N_LOG"
      sudo profiles renew -type enrollment
      afplay '/System/Library/Sounds/Hero.aiff'
      isApproved=$(profiles status -type enrollment | grep -o "User Approved")
      sleep 15
    done

    if [[ -z "$isApproved" ]]; then
      echo "FAILURE: Failed to install ADE profile after 3 minutes!" >>"$DEP_N_LOG"
      echo "Continuing on for manual install" >>"$DEP_N_LOG"
    else
      echo "Enrollment Profile Installed" >>"$DEP_N_LOG"
      exitMigrationApp 0
    fi
}

function installManually() {
  echo "Installing profile manually." >>"$DEP_N_LOG"
  # Checks macOS version in order to install MDM the best way possible.
  echo "Status: Checking macOS version compatibility." >>"$DEP_N_LOG"
  sleep 1

  osVersion=$(sw_vers -productVersion | awk -F. '{print $1}')
  majorVersion=$(sw_vers -productVersion | awk -F. '{print $2}')
  minorVersion=$(sw_vers -productVersion | awk -F. '{print $3}')

  if [[ $osVersion -eq 10 && $majorVersion -lt 13 ]] || [[ $osVersion -eq 10 && $majorVersion -eq 13 && $minorVersion -lt 2 ]]; then
    profiles -IF "/Library/Addigy/mdm-profile-$orgID.mobileconfig"
    echo "Based on detected macOS version, no User Approval needed" >>"$DEP_N_LOG"
  elif [[ $osVersion -eq 10 && $majorVersion -gt 13 ]] || [[ $osVersion -ge 11 ]] && [[ $osVersion -lt 13 ]]; then
    echo "Command: MainText: $olderInstallDirections" >>"$DEP_N_LOG"
    open "/System/Library/PreferencePanes/Profiles.prefPane" "/Library/Addigy/mdm-profile-$orgID.mobileconfig"
    echo "This device is on ${osVersion}.${majorVersion}.${minorVersion}. Opening Preferences Pane: User approval is needed." >>"$DEP_N_LOG"
  elif [[ $osVersion -gt 12 ]]; then
    echo "Command: MainText: $newerInstallDirections" >>"$DEP_N_LOG"
    open "x-apple.systempreferences:com.apple.Profiles-Settings.extension" "/Library/Addigy/mdm-profile-$orgID.mobileconfig"
    echo "This device is on ${osVersion}.${majorVersion}.${minorVersion}. Opening Settings Extension: User approval is needed." >>"$DEP_N_LOG"
  else
    profiles -IF "/Library/Addigy/mdm-profile-$orgID.mobileconfig"
    open "/System/Library/PreferencePanes/Profiles.prefPane"
  fi
  sleep 3

  isApproved=$(profiles status -type enrollment | grep -o "User Approved")
  counter=0
  while [ -z "$isApproved" ] && [ "$counter" -lt "30" ]; do
    ((counter++))
    echo "Waiting for enrollment profile to be installed.  Counter is at: $counter" >>"$DEP_N_LOG"
    isApproved=$(profiles status -type enrollment | grep -o "User Approved")
    afplay '/System/Library/Sounds/Hero.aiff'
    sleep 10
  done

  if [ -z "$isApproved" ]; then
    echo "Failure: Enrollment Profile never installed." >>"$DEP_N_LOG"
    exitMigrationApp 1
  else
    echo "Finished: Enrollment Profile installed." >>"$DEP_N_LOG"
    exitMigrationApp 0
  fi
}

function promoteUser() {
  sudo dscl . -merge /Groups/admin GroupMembership $currentUser
  echo "[Promotion for $currentUser complete]" >>"$DEP_N_LOG"
  touch /Users/$currentUser/.tempPromoted
}

function demoteUser () {
  FILE="/Users/$currentUser/.tempPromoted"
  if [[ -f "$FILE" ]]; then
    echo "$FILE exists, demoting and removing flag"
    sudo dseditgroup -o edit -d $currentUser -t user admin
    rm /Users/$currentUser/.tempPromoted
    launchctl unload "$pathPlist" &>/dev/null
    rm "$shellscriptPath"
    rm "$pathPlist"
    echo "[Demotion for $currentUser complete]" >>"$DEP_N_LOG"
  fi
}

function closeProfilesWindow() {
  # Ensure System Preferences is closed before we do anything; avoids issue where Profiles pane is restricted.
  osVersion=$(sw_vers -productVersion | awk -F. '{print $1}')
  if [[ $osVersion -ge 13 ]]; then
    sysPrefApp="System Settings"
  else
    sysPrefApp="System Preferences"
  fi

  if [[ $(ps aux | grep -v grep | grep "$sysPrefApp" | awk '{print $2}') != '' ]]; then
    for proc in $(ps aux | grep -v grep | grep "$sysPrefApp" | awk '{print $2}'); do
      kill -9 "$proc"
    done
  else
    echo "No $sysPrefApp app to close." >>"$DEP_N_LOG"
  fi
}

function removeProfiles() {
  # Check if wifi settings provided, if not null then force new connection to not lose connectivity.
  if [ -n "${managedSSID}" ]; then
    joinTemporaryWiFi
  else
    echo "No WiFi Credentials provided, not switching networks." >>"$DEP_N_LOG"
  fi

  # Removes orphaned profiles if any
  sudo profiles sync

  # Detects specific MDM, else does generic removal
  profilesXML=$(/usr/bin/profiles list -output stdout-xml | /usr/bin/xmllint --xpath '//dict[key = "_computerlevel"]/array/dict[key = "ProfileItems"]/array/dict[key = "PayloadType" and string = "com.apple.mdm"]' - 2>/dev/null)
  mdmURL=$(echo "$profilesXML" | /usr/bin/xmllint --xpath '//dict[key = "PayloadContent"]/dict/key[text() = "ServerURL"]/following-sibling::string[1]/text()' - 2>/dev/null)
  serverURL=$(echo "$mdmURL" | awk -F '/' '{print $3}')

  if [[ "$serverURL" == *"awmdm"* ]]; then
    echo "Status: WorkspaceOne profile detected." >>"$DEP_N_LOG"
    sleep 1
    removeWorkspaceOne
  elif [[ "$serverURL" == *"jamf"* ]]; then
    echo "Status: Jamf profile detected." >>"$DEP_N_LOG"
    sleep 1
    removeJamf
  elif [[ "$serverURL" == *"kandji"* ]]; then
    echo "Status: Kandji profile detected." >>"$DEP_N_LOG"
    sleep 1
    removeKandji
  else
    echo "Status: Non Addigy MDM found. Removing MDM profiles..." >>"$DEP_N_LOG"
    for id in $(profiles -L | awk "/attribute/" | awk '{print $4}'); do
      profiles -R -p $id
      echo "Status: Installed profile $id removed." >>"$DEP_N_LOG"
      sleep 1
    done
    echo "Status: Installed profile(s) removed." >>"$DEP_N_LOG"
  fi

  ## Wait and Confirm MDM was removed. Exit after timeout. !!!!!!
  local IFS=$'\n'
  local count=0
  DeviceProfiles=($(sudo profiles -P | grep _computerlevel))
  while [[ "${#DeviceProfiles[*]}" != "0" ]]; do
    DeviceProfiles=($(sudo profiles -P | grep _computerlevel))
    echo "Status: Waiting for MDM Profiles to be removed" >>"$DEP_N_LOG"
    sleep 1
    ((count++))
    if [[ $count -gt "180" ]]; then
      echo "Status: There was an error removing the old MDM. Please contact IT to migration." >>"$DEP_N_LOG"
      echo "ERROR: MDM Profiles Removal did not work or timed out" >/Library/Addigy/migration-status.txt
      exitMigrationApp 1
    fi
  done

  closeProfilesWindow
}


function removeWorkspaceOne() {
  echo "Status: Removing Workspace One profiles." >>"$DEP_N_LOG"
  echo "Initiating Enterprise Wipe API to remove Non-Removable Profiles." >>"$DEP_N_LOG"
  # encode user/pass in base64 for basic auth - WS1 auth requirement
  auth64=$(echo -n "$apiUser:$apiPass" | base64)
  headers=(-H "aw-tenant-code: $apiKey" -H "Authorization: Basic $auth64" -H "Content-Length: 0" -H "Content-Type: application/json" -H "Accept: application/json")

  # Removes non-removable MDM profiles by Enterprise Wipe api call
  curl -s "${headers[@]}" --location --request POST "$apiURL/mdm/devices/commands?command=EnterpriseWipe&searchBy=SerialNumber&id=$serialNumber"
 
  # Force sync to get new status quickly
  hubcli sync
  
  echo "Status: Waiting for WorkspaceOne profiles to be removed.  This can take up to 10 minutes." >> "$DEP_N_LOG"
  # Get only device profiles to avoid user based ones that get stuck.
  DeviceProfiles=($(sudo profiles -P | grep _computerlevel))
  while [[ "${#DeviceProfiles[*]}" != "0" ]]; do
    DeviceProfiles=($(sudo profiles -P | grep _computerlevel))
    sleep 10
    ((count++))
    if [[ $count -eq "12" ]]; then
      echo "Warning: Profiles are still present after 2 minutes, forcing Hub reinstall." >> "$DEP_N_LOG"
      pkill -f /Applications/Intelligent\ Hub.app/
      sudo sh /Library/Scripts/hubuninstaller.sh
      sudo curl https://packages.vmware.com/wsone/VMwareWorkspaceONEIntelligentHub.pkg --output /tmp/WS1.pkg
      sudo installer -pkg /tmp/WS1.pkg -target /
    fi
    if [[ $count -eq "60" ]]; then
      echo "ERROR: Removal Failed after 10 minutes!" >> "$DEP_N_LOG"
      # Make script resume - and sudo reboot
      exitMigrationApp 1
    fi
  done

  # Delete device from UEM Console if desired
  if [[ $deleteFromMDM == 'yes' ]]; then
    curl -s "${headers[@]}" --location --request DELETE "$apiURL/mdm/devices?searchBy=SerialNumber&id=$serialNumber"
    echo "Device deleted from UEM Console" >>"$DEP_N_LOG"
  fi
}

function removeJamf() {
  echo "Status: Removing Jamf profiles." >>"$DEP_N_LOG"
  ## [Replace with Jamf specific code]
}

function removeKandji() {
  echo "Status: Removing Kandji profiles." >>"$DEP_N_LOG"
  ## [Replace with Kandji specific code]
}

function installAgent() {
  sudo curl -o /tmp/cli-install https://agents.addigy.com/cli-install.sh 
  sudo chmod +x /tmp/cli-install 
  sudo /tmp/cli-install realm=prod orgid="$targetOrgID" policy_id="$targetPolicyID"
  echo "Status: Addigy Agent Installed" >>"$DEP_N_LOG"
  sleep 5
}

function exitMigrationApp() {
  closeProfilesWindow

  if [ "$1" = 0 ]; then
    echo "Status: Addigy installed, checking for policies.  This will take at least a few minutes." >>"$DEP_N_LOG"
    /Library/Addigy/go-agent policier run 2>/tmp/out.txt
    # Waiting for profiles to be installed.
    sleep 60

    disconnectTemporaryWiFi
  fi
  
  demoteUser

  echo "Exiting App with code $1" >>"$DEP_N_LOG"
  echo "Command: Quit" >>"$DEP_N_LOG"
  mv "$DEP_N_LOG" "/var/tmp/depnotify_results.log"
  mv "$DEP_N_DEBUG" "/var/tmp/debug_depnotify_results.log"
  rm -rf /Library/LaunchDaemons/com.migrator.plist
  rm -rf /tmp/agent_migrator.sh
  sudo launchctl unload /Library/LaunchDaemons/com.migrator.plist
  kill -9 $caffeinatePID
  exit $1
}

######################################################################################################
# Begin Execution ####################################################################################
######################################################################################################

if [ -z "${MDMLink}" ]; then
  echo "MDM Link variable was left empty! Update Migration Script to fix this. Exiting Script..." >>"$DEP_N_LOG"
  exitMigrationApp 1
fi

#*******************************************************************************
# Step 1: Pre-Login Work, Install DEPNotify, set logfiles                      *
#*******************************************************************************

# Caffeinate this script
caffeinate -d -i -m -u &
caffeinatePID=$!

# Install DEPNotify
curl --silent --output /tmp/DEPNotify-1.1.6.pkg "https://s3.amazonaws.com/nomadbetas/DEPNotify-1.1.6.pkg" >/dev/null
sudo installer -pkg /tmp/DEPNotify-1.1.6.pkg -target /

# Check if DEPNotify is running
DEP_NOTIFY_PROCESS=$(pgrep -l "DEPNotify" | cut -d " " -f1)
  until [ "$DEP_NOTIFY_PROCESS" = "" ]; do
    echo "Stopping the previously-opened instance of DEPNotify."
    kill $DEP_NOTIFY_PROCESS
    DEP_NOTIFY_PROCESS=$(pgrep -l "DEPNotify" | cut -d " " -f1)
  done
rm /Users/"$ACTIVE_USER"/Library/Preferences/menu.nomad.DEPNotify* >/dev/null 2>&1
killall cfprefsd

# Create DEPNotify log files
touch "$DEP_N_DEBUG"
touch "$DEP_N_LOG"

# Configure DEPNotify General Settings
echo "Command: MainTitle: $MAIN_TITLE" >>"$DEP_N_LOG"
echo "Command: MainText: $MAIN_TEXT" >>"$DEP_N_LOG"
echo "Status: Starting Up...." >>"$DEP_N_LOG"
#echo "Command: WindowStyle: ActivateOnStep" >>"$DEP_N_LOG"

# Wait for active user session
FINDER_PROCESS=$(pgrep -l "Finder")
until [ "$FINDER_PROCESS" != "" ]; do
  echo "$(date "+%Y-%m-%d %H:%M:%S"): Finder process not found. User session not active." >>"$DEP_N_DEBUG"
  sleep 1
  FINDER_PROCESS=$(pgrep -l "Finder")
done

#*******************************************************************************
# Step 2. Wait for logged in user, start DEPNotify                             *
#*******************************************************************************

currentUser=$(ls -la /dev/console | cut -d' ' -f4)
currentUserID=$(id -u $currentUser)
echo "$currentUser is the current user with ID: $currentUserID" >>"$DEP_N_LOG"

# Promote User if not an admin
if [[ $(dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep "$currentUser") != "" ]]; then
  echo "User is already an admin" >>"$DEP_N_LOG"
else
  promoteUser
fi

# Start DEPNotify screen
echo "Starting DEPNotify" >>"$DEP_N_LOG"
launchctl asuser $currentUserID open -a "$DEP_N_APP" --args -path "$DEP_N_LOG"

echo "Status: Checking for Addigy Agent" >>"$DEP_N_LOG"
sleep 1

targetOrgID=$(echo "${MDMLink}" | awk -F '/' '{print $6}')
targetPolicyID=$(echo "${MDMLink}" | awk -F '/' '{print $7}')

#*******************************************************************************
# Step 3. Install Agent                                                        *
#*******************************************************************************

if [ -d "/Library/Addigy/" ]; then
  #get installed agent's orgid and policyid to compare, if not same, install again.
  orgID=$(cat /Library/Addigy/config/.adg_agent_config | grep -i "orgid" | sed '/orgid /s///')
  policyID=$(cat /Library/Addigy/config/.adg_agent_config | grep -i "policy_id" | sed '/policy_id /s///')
  realm=$(cat /Library/Addigy/config/.adg_agent_config | grep -i "realm" | sed '/realm /s///')

  echo "Target orgID: $targetOrgID" >>"$DEP_N_LOG"
  echo "Target policyID: $targetPolicyID" >>"$DEP_N_LOG"

  if [ "$targetOrgID" != "$orgID" ] || [ "$targetPolicyID" != "$policyID" ]; then
    echo "Status: Re-Installing Addigy Agent with new org/policy" >>"$DEP_N_LOG"
    sleep 1
    installAgent
  else
    echo "Status: Addigy Agent already installed" >>"$DEP_N_LOG"
    sleep 1
  fi

else
  echo "Status: Installing Addigy Agent" >>"$DEP_N_LOG"
  sleep 1
  installAgent
fi

#*******************************************************************************
# Step 4. Remove Other Profiles                                                *
#*******************************************************************************

# Download Addigy MDM Profile, remove previous if exists.
rm -f "/Library/Addigy/mdm-profile-$orgID.mobileconfig"
if [[ $targetPolicyID != "" ]]; then
  echo "Downloading MDM with Policy" >>"$DEP_N_LOG"
  MDMInstallLink="https://mdm-$realm.addigy.com/mdm/enroll/$orgID/$targetPolicyID"
else
  echo "Downloading MDM without Policy" >>"$DEP_N_LOG"
  MDMInstallLink="https://mdm-$realm.addigy.com/mdm/enroll/$orgID"
fi
/Library/Addigy/go-agent download "$MDMInstallLink" "/Library/Addigy/mdm-profile-$orgID.mobileconfig"
echo "Status: Downloading Addigy MDM Profile." >>"$DEP_N_LOG"
sleep 5

MDMProfileIdentifier="com.github.addigy.mdm.mdm"
installedAPNTopic=$(/usr/sbin/system_profiler SPConfigurationProfileDataType | awk '/Topic/{ print $NF }' | sed 's/[";]//g')
downloadedAPNTopic=$(security cms -D -i "/Library/Addigy/mdm-profile-$orgID.mobileconfig" | xmllint --pretty 1 - | grep -A1 "Topic" | grep "string" | cut -d '>' -f2 | cut -d '<' -f1)

#Checks whether installed MDM Root Certificate is from Addigy; if not remove installed profiles.
if sudo profiles -P | grep $MDMProfileIdentifier &>/dev/null; then
  if [[ $installedAPNTopic == $downloadedAPNTopic ]]; then
    echo "Success: Addigy profile is already installed." >>"$DEP_N_LOG"
    exitMigrationApp 0
  else
    echo "Addigy profile is not correct, reinstalling." >>"$DEP_N_LOG"
    removeProfiles
  fi
#If Non Addigy MDM is found then remove profiles
elif [ -n "$installedAPNTopic" ]; then
  echo "MDM profiles exist." >>"$DEP_N_LOG"
  removeProfiles
else
  echo "Status: No MDM profiles currently installed." >>"$DEP_N_LOG"
fi
sleep 3

#*******************************************************************************
# Step 5. Install Addigy Profiles                                              *
#*******************************************************************************

# Check if ADE, if not install from downloaded profile.
if [[ $(cat "${csvPath}" | grep "$serialNumber") == *"$serialNumber"* ]] || [ $allADE == "yes" ]; then
  installADE
else
  installManually
fi

EOF

cat <<"EOF" >/Library/LaunchDaemons/com.migrator.plist
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.migrator</string>
    <key>ProgramArguments</key>
    <array>
      <string>sh</string>
      <string>/tmp/agent_migrator.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>/tmp</string>
    <key>StandardOutPath</key>
    <string>/tmp/Addigy_Migrator/logs/migrator.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/Addigy_Migrator/logs/migrator.log</string>
  </dict>
  </plist>
EOF

sudo launchctl load /Library/LaunchDaemons/com.migrator.plist
