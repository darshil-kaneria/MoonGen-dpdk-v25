# Moongen Wire Example: Simulation of Wire Lengths

This scripts forwards packets from one source port to one destination port with a precise delay (measured standard deviation of ~ 3.2 ns). This is done by capturing receive timestamps and sending the packets at a specific time by sending invalid packets in between the forwarded packets. The sending time of the first packet is determined by the capturing a single TX timestamp. When the transmit queue can not be keep full, all following packets will have a larger delay, which is not detected or corrected by this script.

## Hardware
This script was developed and tested on Intel E810-CQDA2 100G NICs. It requires TX timestamping capabilities for selected packets and RX timestamping for all received packets.

## OS Setup
To be able to allocate a large receive buffer (7000000 packets, which can be buffered), 1G Hugepages need to be allocated. This can be done using the following commands, which allocate 16GB of buffer space. "node0" needs to be adapted to the NUMA node, where the NIC is connected to.

    echo 16 > /sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages
    mkdir /mnt/hugepages1G
    mount -t hugetlbfs -o pagesize=1G none /mnt/hugepages1G

## Build
Run the following commands in this directory to build the required shared library for this script:

    mkdir build
    cd build
    cmake ..
    make

## Example
To execute the script (e.g. from port 0 to port 1) run the following command inside the previously created build directory:

    /root/moongen/build/MoonGen /root/moongen/examples/wire/wire.lua 0 1

The default delay is 10 ms. It can be changed using the -d parameter.
