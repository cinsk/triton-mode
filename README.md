
triton-mode
===========

Prerequisites
-------------

1. Install triton command line tool, and configure Triton profiles.  See [this document](https://docs.joyent.com/public-cloud/api/triton-cli) for the instructions.
2. Optionally, install `pssh`.  On Mac, you could do `brew install pssh`.

It is possible to use *triton-mode* without `pssh`, but you will be unable to run a command on multiple machines.  Especially `P` command.

Installation
------------

Download this package using:

        $ git clone https://github.com/cinsk/triton-mode.git

Assuming that triton-mode/ is placed in `~/triton-mode`, add following sexp to your Emacs init file:

        (add-to-list 'load-path (expand-file-name "~/triton-mode"))
        (require 'triton-mode)


Usage
-----

`M-x triton` will launch a buffer per Triton profile.  It will first ask you to select the profile.

TODO: Add more

TODO
----

1. Convert most `defvar` to `defcustom` styles for better configuration management.
2. To upload this package to MELPA or other Emacs package repository
   package.
3. Implements feature to launch/stop/update Triton Compute instances.
