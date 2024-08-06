# Process
To migrate from WorkspaceOne to Addigy our migration process looked like this:

**Devices get migration script from WorkspaceOne**
  - Self Service is best option, allowing user interaction for accepting profile
    
**User executes Addigy migration script**
  - Addigy agent installed
  - API Call to WS1 to execute Enterprise Wipe to remove non-removable profiles
  - Addigy profiles get installed
    
**Device registers with Addigy**
  - Detects Workspace Hub installed - removes it after addigy mdm profiles detected
  - Anomalies are shown in flex policies



The reason the migration script was deployed by WS1 with self service is the instant execution.  When using Addigy policy software or scripts, there were variations in the execution time, some users waited up to 30 minutes for the migration screen.  I wanted something for a user to initiate and see immediate results.  

This process took around 10 minutes for each device and was very successful.  

Most issues came down to two causes:
  - Workspace One Hub was not updated lately, and would not get the commands from console.
    - A full uninstall/reinstall was needed of the hub.
  - The MacOS enrollment profile popup/notification did not occur.
    - A reboot of the computer was necessary.  Executing the script again after restart had no issue.

# Workspace One

We need to create an api key and user with the role to modify devices.  This is done in the UEM console in three steps.

>***Ensure you are in the highest hierarchy level in UEM to ensure every device can be migrated.***


**Generate the REST API key**
  1. On the Workspace ONE UEM console, go to Groups & Settings > All Settings > System > Advanced > API > REST API.
  2. Your API Key will be generated and shown in the API Key box.
  3. Click Save.

**Create a role with the API permissions**
  1. On the Workspace ONE UEM console, go to Accounts > Administrators > Roles.
  2. From the Roles list select the Read Only role and click Copy.
  3. In the Copy Role window enter a Name and Description for this new role.
     - Name - api_migration_role.
     - Description - Role for migration to Addigy.
  4. In Categories section go to these options and set them to Edit:
     - API > REST > Devices.
     - Click Save.

**Create the Administrator account**
  1. Go to Accounts > Administrators > List View click Add and select Add Admin.
  2. On the Basic tab, enter applicable information in all the fields marked with (*).
  3. On the Roles tab, select the Child Organization group and the api_admin_role that you created previously.
  4. Click Save.



# Addigy
**Create Policy for the migrated devices**
  - In Addigy we set up policies to show various issues and execute cleanup scripts.  The removal of WorkspaceOne hub is done in Addigy to ensure agent cli commands are not lost in case of migration issues.
  - Ensure no other orginizational settings/profiles/software will interfere
  - Get Policy ID string for the migration script on upper right.


# Workspace One
**Modify and Assign Migration Script**
  - Edit the migration script with the values from Addigy and WS1.
  - Add the script to the self service hub in WS1 for the users.


# Cleanup

**Create Flex Policies**

These assist you in easily finding devices that need some attention, and cleanup of old mdm agent.

1. Workspace One Managed
   - This showed us devices that didn’t get a successful removal of ws1 profiles.
   - Flex Assignment: Installed Profiles contains ws1profileUUID
   - Get the profileUUID from **sudo profiles show** on a WS1 managed device

2. Unmanaged Devices
   - This showed us devices that failed in the process, like user didn’t accept the profile.
   - Flex Assignment: Installed Profiles does not contain addigyprofilestring
     - Get profilestring from **sudo profiles show** on an Addigy managed device
     - Has MDM != True/On

3. Workspace One Hub Installed
   - This will remove the hub from devices
   - Assign the script as a software
   - Create Custom Fact (See Below)
   - Create Monitor with Remediation (See Below)

WS1Hub Device Fact
```
if [ ! -d "/Applications/Workspace ONE Intelligent Hub.app" ]; then
  echo "false"
else
  echo "true"
fi
```

WS1Hub Remediation
```
#!/bin/bash


#Remove only if Addigy already installed
MDMProfileIdentifier="com.github.addigy.mdm.mdm"
if sudo profiles -P | grep $MDMProfileIdentifier >& /dev/null; then
   sudo sh /Library/Scripts/hubuninstaller.sh
else
   echo "Addigy MDM is not installed. Wait for Migration"
   exit 1
fi
```
