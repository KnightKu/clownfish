#!/bin/bash
#
# License:      GNU General Public License (GPL)
# 
# lustre_server
#      Description: Manages a lustre_server on a shared storage medium.
#  Original Author: Eric Z. Ayers (eric.ayers@compgen.com)
# Original Release: 25 Oct 2000
#
# Rewritten Filesystem agent to lustre_server agent by bschubert@ddn.com
#
# usage: ./lustre_server {start|stop|status|monitor|validate-all|meta-data}
#
#         OCF parameters should include
#         OCF_RESKEY_service
#         OCF_RESKEY_options can be speicified.
#
# OCF_RESKEY_service : the name of the service, e.g. fsname-OST000a, or
#                      MGS ID in clownfish.conf, e.g. lustre_mgs
# OCF_RESKEY_options : options to be given to the mount command via -o
#
#
# NOTE: There is no locking (such as a SCSI reservation) being done here.
#       I would if the SCSI driver could properly maintain the reservation,
#       which it cannot, even with the 'scsi reservation' patch submitted
#       earlier this year by James Bottomley.  The patch minimizes the
#       bus resets caused by a RESERVATION_CONFLICT return, and helps the
#       reservation stay when 2 nodes contend for a reservation,
#       but it does not attempt to recover the reservation in the
#       case of a bus reset.
#
#       What all this means is that if 2 nodes mount the same file system
#       read-write, the filesystem is going to become corrupted. However
#       Lustre provides the Multi-Mount-Protection feature (MMP).
#
#       As a result, you should use this together with the stonith option
#       and redundant, independent communications paths.
#
#       If you don't do this, don't blame us when you scramble your disk.
#
#       Note:  the ServeRAID controller does prohibit concurrent acess
#       In this case, you don't actually need STONITH, but redundant comm is
#       still an excellent idea.
#

#######################################################################
# Initialization:

. ${OCF_ROOT}/resource.d/heartbeat/.ocf-shellfuncs

#######################################################################
HOSTOS=`uname`
FSTYPE="lustre"

# FIXME: OCF_DEBUG officially supported in the the mean time?
#OCF_DEBUG=yes

usage() {
        cat <<EOT
        usage: $0 {start|stop|status|monitor|validate-all|meta-data}
EOT
}

meta_data() {
        cat <<END
<?xml version="1.0"?>
<!DOCTYPE resource-agent SYSTEM "ra-api-1.dtd">
<resource-agent name="lustre_server">
<version>1.0</version>


<longdesc lang="en">
  Resource script for lustre_server. It manages a lustre_server on a shared storage medium. 
</longdesc>
<shortdesc lang="en">lustre_server resource agent</shortdesc>

<parameters>
<parameter name="service">
 <longdesc lang="en">
   the name of the Lustre service, e.g. fsname-OST000a, or MGS ID in clownfish.conf, e.g. lustre_mgs
 </longdesc>
 <shortdesc lang="en">servive name</shortdesc>
 <content type="string" default="" />
</parameter>

<parameter name="options">
 <longdesc lang="en">
  Any extra options to be given as -o options to mount.
 </longdesc>
 <shortdesc lang="en">options</shortdesc>
 <content type="string" default="" />
</parameter>
</parameters>

<actions>
 <action name="start" timeout="300" />
 <action name="stop" timeout="300" />
 <action name="monitor" depth="0" timeout="300" interval="120" start-delay="10" />
 <action name="validate-all" timeout="5" />
 <action name="meta-data" timeout="5" />
 </actions>
</resource-agent>
END
}

#
#       Make sure the kernel does the right thing with the FS buffers
#       This function should be called after unmounting and before mounting
#       It may not be necessary in 2.4 and later kernels, but it shouldn't hurt
#       anything either...
#
#       It's really a bug that you have to do this at all...
#
flushbufs() {
    if have_binary $BLOCKDEV ; then
       $BLOCKDEV --flushbufs $1
    fi
    return 0
}

# Figure out the real device number of external journals
# we need to provide as mount options, since the block
# device only know major/minor of the the journal device and it
# might/will change dynamically on reboots and between servers
# It would be MUCH better if 'mount' would do it on its own
# and in fact mount is already linked against libblkid to do
# this job
get_external_journal_device()
{
        UUID=`dumpe2fs -h $DEVICE 2>/dev/null | awk '/^Journal UUID/{print $3}'`
        if [ -z "$UUID" ]; then
                # device has internal journal, not need to proceed
                return
        fi

        # prefer /dev/mapper/
        JDEV="`blkid -t UUID=$UUID /dev/mapper/* | awk -F: '{print $1}'`"
        if [ -z "$JDEV" ]; then
                JDEV="`blkid -t UUID=$UUID | awk -F: '{print $1}'`"
        fi

        if [ -z "$JDEV" ]; then
                # know the journal is on an external device, but we can't find it
                ocf_log err "Cannot find device with journal UUID $UUID"
                return $OCF_ERR_GENERIC
        fi

        DEVNUM="`stat -c %02t%02T $JDEV`"
        if [ -z "$DEVNUM" ]; then
                ocf_log err "Failed to retrieve device number of Journal device"
                return $OCF_ERR_GENERIC
        fi

        # add 0x only here, because we couldn't check for an empty string otherwise
        DEVNUM="0x$DEVNUM"

        echo $DEVNUM
        return 0
}

# Take advantage of /proc/mounts if present, use portable mount command
# otherwise. Normalize format to "dev mountpoint fstype".
list_mounts() {
        mtab=/proc/mounts
        if [ ! -f $mtab ]; then
                ocf_log err "$mtab is missing!"
                exit $OCF_ERR_GENERIC
        fi
        cat $mtab | cut -d' ' -f1,2,3
}

lustre_health_check()
{
	check=$(lctl get_param -n health_check 2>&1)
        # on first check the lustre modules are not loaded yet
        if [ $? != 0 ]; then
                return 0
        fi

        if [ "$check" = "healthy" ]; then
                return 0
        else
                ocf_log err "health_check is $check"
                return 1
        fi
}

#
# START: Start up the filesystem
#
lustre_server_start()
{
        output=$(clf_local start $SERVICE_UUID)
        retval=$?
        if [ $? -ne 0 ]; then
                ocf_log err "failure of clf_local start"
                return $retval
        fi
        return 0
}
# end of lustre_server_start

#
# STOP: Unmount the filesystem
#
lustre_server_stop()
{
        output=$(clf_local stop $SERVICE_UUID)
        retval=$?
        if [ $? -ne 0 ]; then
                ocf_log err "failure of clf_local stop"
                return $retval
        fi
        return 0
}
# end of lustre_server_stop

#
# MOUNTED: is the filesystem mounted or not?
#
lustre_server_mounted()
{
        if list_mounts | grep -q " $MOUNTPOINT " >/dev/null 2>&1; then
                rc=$OCF_SUCCESS
                msg="$MOUNTPOINT is mounted (running)"
        else
                rc=$OCF_NOT_RUNNING
                msg="$MOUNTPOINT is unmounted (stopped)"
        fi

        # check in all mntdevs if really not mounted
        # lustre bug 21359 (https://bugzilla.lustre.org/show_bug.cgi?id=21359)
        if [ $rc -eq $OCF_NOT_RUNNING ]; then
		dev=$(lctl get_param -n mds.*.mntdev 2>&1)
		if [ $? = 0 ]; then
			MNTDEVS=$dev
		fi
		dev=$(lctl get_param -n obdfilter.*.mntdev 2>&1)
		if [ $? = 0 ]; then
			MNTDEVS="$MNTDEVS $dev"
		fi
		dev=$(lctl get_param -n mgs.MGS.mntdev 2>&1)
		if [ $? = 0 ]; then
			MNTDEVS="$MNTDEVS $dev"
		fi
		for i in $MNTDEVS; do
			if [ "$i" = "$DEVICE" ]; then
                                ocf_log err "Bug21359, /proc/mounts claims device is not mounted, but $i proves this is wrong"
                                rc=$OCF_ERR_GENERIC
                        fi
                done

        fi

        if [ "$OCF_DEBUG" = "yes" ]; then
                ocf_log info "$msg"
        fi

        case "$OP" in
        status) ocf_log info "$msg"
                ;;
        monitor)
                if [ $rc -ne $OCF_SUCCESS ]; then
                        ocf_log err "$msg"
                fi
        esac

        return $rc
}
# end of lustre_server_mounted

#
# STATUS: is the filesystem mounted and healthy or not?
#
lustre_server_status()
{
        lustre_health_check
        if [ $? -ne 0 ]; then
                return ${OCF_ERR_GENERIC}
        fi

        lustre_server_mounted
        rc=$?

        return $rc
}
# end of lustre_server_status

#
#       Check if Lustre is available at all
#
lustre_server_validate_all()
{
	var=$(lctl get_param -n version 2>&1)
	if [ $? != 0 ]; then
		modprobe lustre

		for i in `seq 1 10`; do
			var=$(lctl get_param -n version 2>&1)
			if [ $? != 0 ]; then
				sleep 1
			else
				break
			fi
		done

		var=$(lctl get_param -n version 2>&1)
		if [ $? != 0 ]; then
			ocf_log err "Failed to load the lustre module"
			return $OCF_ERR_GENERIC
		fi
	fi

        return $OCF_SUCCESS
}

# Check the arguments passed to this script
if [ $# -ne 1 ]; then
        usage
        exit $OCF_ERR_ARGS
fi

OP=$1

if [ "$OCF_DEBUG" = "yes" ]; then
        ocf_log info "OP = $OP"
fi

# These operations do not require instance parameters
case $OP in
meta-data)      meta_data
                exit $OCF_SUCCESS
                ;;
usage)          usage
                exit $OCF_SUCCESS
                ;;
esac

# Check the OCF_RESKEY_ environment variables...
SERVICE_UUID=$OCF_RESKEY_service
if [ ! -z "$SERVICE_UUID" ]; then
        output=$(clf_local locate $SERVICE_UUID)
        if [ $? -ne 0 ]; then
                ocf_log err "failure of clf_local"
                if [ "$OP" = "stop" ]; then
                    exit $OCF_SUCCESS
                else
                    exit $OCF_NOT_RUNNING
                fi
        fi
else
        ocf_log err "OCF_RESKEY_service should be specified"
        exit $OCF_ERR_ARGS
fi

fields=($output)
if [ ${#fields[@]} -ne 2 ]; then
        ocf_log err "unexpected output of clf_local"
        exit $OCF_ERR_ARGS
fi
DEVICE=${fields[0]}
MOUNTPOINT=${fields[1]}

MOUNTPOINT=`echo $MOUNTPOINT | sed -e 's/\s*//'`
if [ -z "$MOUNTPOINT" ]; then
        ocf_log err "Empty mount point!"
        ocf_log err "Please specify the directory"
        exit $OCF_ERR_ARGS
fi

if [ ! -z "$OCF_RESKEY_options" ]; then
        options="-o $OCF_RESKEY_options"
fi

# Check to make sure the utilites are found
check_binary $MODPROBE
check_binary $FSCK
check_binary $MOUNT
check_binary $UMOUNT

if [ "$OP" != "monitor" ]; then
        ocf_log info "Running $OP for $DEVICE on $MOUNTPOINT"
fi

# These operations do not require the clone checking + OCFS2
# initialization.
case $OP in
status|monitor) lustre_server_status
                exit $?
                ;;
validate-all)   lustre_server_validate_all
                exit $?
                ;;
stop)           lustre_server_stop
                exit $?
                ;;
esac

if [ -n "$OCF_RESKEY_CRM_meta_clone" ]; then
        ocf_log err "DANGER! $FSTYPE on $DEVICE is NOT cluster-aware!"
        ocf_log err "DO NOT RUN IT AS A CLONE!"
        ocf_log err "Politely refusing to proceed to avoid data corruption."
        exit $OCF_ERR_GENERIC
fi

case $OP in
start)  lustre_server_start
        ;;
*)      usage
        exit $OCF_ERR_UNIMPLEMENTED
        ;;
esac
exit $?



