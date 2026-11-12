# Thebes Domain Kernel

Luxor builds against the Thebes Domain Kernel at commit `233e233d2deb19e2928579c698a18ab83ebb3e5c`.
The kernel's public repository is published separately; until then this directory names the dependency
and the commit. `tools/packages.sh` reads the kernel from `KERNEL` when it is set, else from this directory
when the kernel's source is placed here, else from a checkout beside this repository (`../thebes-kernel`),
and refuses a checkout at any other commit.
