#!/bin/bash
#################################################################################
#										#
# shaper.sh by Ivica Sakota							#
# version 1.0									#
#										#
# This shaper adds one root class with 3 subclasses				#
# First for interactive priority traffic (like DNS, etc.)			#
# Second to be used by clients behind NAT to share traffic equally		#
# Third is for any unmatched traffic (other temporary clients)			#
#										#
# It also marks firewall packages to fit into classes so be sure		#
# to modify the script to fit your needs					#
#										#
#################################################################################

######### CONFIGURATION START #############

#Device we're shaping
device=`ifconfig ppp | head -n 1  | awk '{print $1}'`

# Max Upload in kilobits as specified by provider
#maxUpload=768
maxUpload=744

# How much of max upload we are allowed to use
# In order for shape to work this needs to be max 80-90%
shapeDownPercent=85

# How much in percent we want to reserve for interactive class
interactivePercent=10

# How much in percent we want to reserve for unmatched packets
unmatchedPercent=10

#How much of total available shaped bandwidth in percent we want to use as a ceil for interactive class
interactiveCeilPercent=90

#How much of total available shaped bandwidth in percent we want to use as a ceil for unmatched class
unmatchedCeilPercent=90

#How much of total available shaped bandwidth in percent we want to use as a ceil for regular class
regularCeilPercent=100

#IP addresses of guaranteed clients
declare -a clients=('192.168.5.1' '192.168.5.2' '192.168.5.3' '192.168.5.4' '192.168.5.5' '192.168.5.6' '192.168.5.7' '192.168.5.8' '192.168.5.9' '192.168.5.11');

#Distribution of interactive bandwidth by class in percentage
#Adding or removing item from array will add/remove interactive subclass automatically
declare -a interactiveClasses=('60' '30' '10');

#tc binary
tcBin=/sbin/tc

#iptables binary
iptablesBin=/sbin/iptables

#SSH port this server is listening on to included it's traffic inside interactive class
sshPort=80

#SSH port we'll be connecting to that requires to go inside interactive class
sshOutPort=22

# Directory to (re)load neccessary kernel modules from
moddir="/lib/modules/`uname -r`/kernel/net/ipv4/netfilter"

# modprobe binary
modprobe=/sbin/modprobe

########### CONFIGURATION END ############

#Root Handle
rootHandle=1

#Root Base
rootBase=1

#Interactive Base
interactiveBase=10

#Regular Class Base
regularBase=50

#Unmatched Class Base
unmatchedBase=99

#Interactive Prio
interactivePrio=1

#Regular Prio
regularPrio=2

#Unmatched Prio
unmatchedPrio=9

# Max bandwidth we are shaping
shapedBandwidth=$(($maxUpload * $shapeDownPercent / 100))

# Bandwidth reserved for interactive packets
interactiveBandwidth=$(($shapedBandwidth * $interactivePercent / 100))

# Bandwidth reserved for unmatched packets
unmatchedBandwidth=$(($shapedBandwidth * $unmatchedPercent / 100))

#Regular bandwidth = shapedBandwidth - interactiveBandwidth - unmatchedBandwidth
regularBandwidth=$(($shapedBandwidth - $interactiveBandwidth - $unmatchedBandwidth))

#Interactive ceil
interactiveCeil=$(($shapedBandwidth * $interactiveCeilPercent / 100))

#Unamatched ceil
unmatchedCeil=$(($shapedBandwidth * $unmatchedCeilPercent / 100))

#Regular ceil
regularCeil=$(($shapedBandwidth * $regularCeilPercent / 100))

#Number of clients with guaranteed bandwidth
clientCount=${#clients[@]}

#Client guaranteeed bandwidth
clientBandwidth=$(($regularBandwidth / $clientCount))

#Default Burst
burst=6

echo Provider upload: $maxUpload KBit "("$(($maxUpload / 8)) KB")"
echo Shaped upload: $shapedBandwidth KBit "("$(($shapedBandwidth / 8)) KB")"
echo Reserved for interactive: $interactiveBandwidth KBit "("$(($interactiveBandwidth / 8)) KB")"
echo Reserved for not matched: $unmatchedBandwidth KBit  "("$(($unmatchedBandwidth / 8)) KB")"
echo Available regular bandwidth: $regularBandwidth KBit "("$(($regularBandwidth / 8)) KB")"
echo Interactive ceil: $interactiveCeil KBit "("$(($interactiveCeil / 8)) KB")"
echo Unmatched ceil: $unmatchedCeil KBit "("$(($unmatchedCeil / 8)) KB")"
echo Regular ceil: $regularCeil KBit "("$(($regularCeil / 8)) KB")"
echo Client guaranteed bandwidth: $clientBandwidth KBit "("$(($clientBandwidth / 8)) KB")"


############# Shaping Start ###########

# load necessary kernel modules
for n in `ls $moddir` ; do
        modname="`echo $n | awk -F. '{print $1}'`"
       $modprobe $modname > /dev/null
done

# clear all shaping before applying new
$tcBin qdisc del dev $device root   >/dev/null 2>&1
#$tcBin qdisc del dev $device ingress
$iptablesBin -t mangle -F
$iptablesBin -t mangle -X

# everything not matched goes to unmatched class
$tcBin qdisc add dev $device root handle "$rootHandle": htb default $unmatchedBase r2q 1

# adding root class
$tcBin class add dev $device parent "$rootHandle": classid "$rootHandle":"$rootBase" htb rate "$shapedBandwidth"kbit ceil "$shapedBandwidth"kbit

# adding interactive subclass
$tcBin class add dev $device parent "$rootHandle":"$rootBase" classid "$rootHandle":"$interactiveBase" htb rate "$interactiveBandwidth"kbit ceil "$interactiveCeil"kbit burst "$burst"k prio $interactivePrio

	#for every percent in interactiveClasses array create new class with specified percentage
        i=$interactiveBase
        for interactivePercent in "${interactiveClasses[@]}"
                do
                        # increment class ID 
                        i=$(($i + 1))
			 $tcBin class add dev $device parent "$rootHandle":"$interactiveBase" classid "$rootHandle":"$i" htb rate "$(($interactiveBandwidth * $interactivePercent / 100 ))"kbit ceil "$interactiveCeil"kbit burst "$burst"k prio $interactivePrio
			 $tcBin qdisc add dev $device parent "$rootHandle":"$i" handle "$i": sfq perturb 10
			 $tcBin filter add dev $device parent "$rootHandle":0 protocol ip prio $interactivePrio handle "$i" fw classid "$rootHandle":"$i"
                done

# adding subclass for regular clients
$tcBin class add dev $device parent "$rootHandle":"$rootBase" classid "$rootHandle":"$regularBase" htb rate "$regularBandwidth"kbit ceil "$regularCeil"kbit burst "$burst"k prio $regularPrio
	i=$regularBase
	for client in "${clients[@]}"
		do
		        # increment class ID for current client
			i=$(($i + 1))
			$tcBin class add dev $device parent "$rootHandle":"$regularBase" classid "$rootHandle":"$i" htb rate "$clientBandwidth"kbit ceil "$regularCeil"kbit burst "$burst"k prio $regularPrio
			$tcBin qdisc add dev $device parent "$rootHandle":"$i" handle "$i": sfq perturb 10
			$tcBin filter add dev $device parent "$rootHandle":0 protocol ip prio $regularPrio handle "$i" fw classid "$rootHandle":"$i"
		done

# adding class for unmatched traffic
$tcBin class add dev $device parent "$rootHandle":"$rootBase" classid "$rootHandle":"$unmatchedBase" htb rate "$unmatchedBandwidth"kbit ceil "$unmatchedCeil"kbit burst "$burst"k prio $unmatchedPrio
$tcBin qdisc add dev $device parent "$rootHandle":"$unmatchedBase" handle "$unmatchedBase": sfq perturb 10
$tcBin filter add dev $device parent "$rootHandle":0 protocol ip prio $unmatchedPrio handle "$unmatchedBase" fw classid "$rootHandle":"$unmatchedBase"

############# Marking Interactive Packets in Firewall ##########

#DNS from server
$iptablesBin -t mangle -A OUTPUT -m udp -p udp --dport 53 -j MARK --set-mark $(($interactiveBase + 1))
$iptablesBin -t mangle -A OUTPUT -m udp -p udp --dport 53 -j RETURN

#DNS from clients behind NAT
$iptablesBin -t mangle -A POSTROUTING -s 192.168.5.0/24 -m udp -p udp --dport 53 -j MARK --set-mark $(($interactiveBase + 1))
$iptablesBin -t mangle -A POSTROUTING -s 192.168.5.0/24 -m udp -p udp --dport 53 -j RETURN

### SSH to outside SSH servers
$iptablesBin -t mangle -A OUTPUT -m tcp -p tcp --dport $sshOutPort -j MARK --set-mark $(($interactiveBase + 2))
$iptablesBin -t mangle -A OUTPUT -m tcp -p tcp --dport $sshOutPort -j RETURN

### Incoming SSH connections
$iptablesBin -t mangle -A INPUT -m tcp -p tcp --dport $sshPort -j MARK --set-mark $(($interactiveBase + 2))
$iptablesBin -t mangle -A INPUT -m tcp -p tcp --dport $sshPort -j RETURN

############# Marking Client Packets in Firewall  ##########

i=$regularBase
for client in "${clients[@]}"
	do
        	# increment ID for current client
                i=$(($i + 1))
		$iptablesBin -t mangle -A POSTROUTING -s $client -j MARK --set-mark $i
		$iptablesBin -t mangle -A POSTROUTING -s $client -j RETURN
       done

########## Marking Unmatched Packets in Firewall ##########

$iptablesBin -t mangle -A POSTROUTING -j MARK --set-mark $unmatchedBase


#Clamp Fix
$iptablesBin -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo Shaping done!
echo
echo To list classes use: 
echo	$tcBin -s -d qdisc show dev $device
echo	$tcBin -s -d class show dev $device
echo  	$iptablesBin --list -t mangle
