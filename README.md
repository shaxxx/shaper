This script excpects few (standard) things

- Linux machine as a LAN gateway
- iptables and tc binaries installed
- netfilter kernel support
- traffic divided into 3 categories: priority, standard and junk/unmatched
- clients with fixed IP addresses

To use it first configure your maximum upload by provider 
(minus 15-20 percent for shaping to actually work), set limits
for each category and enter known clients to share the upload.



