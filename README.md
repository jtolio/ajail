# ajail

a basic, simplistic jail for running programs you don't completely trust. ajail
is just a nice helper around 
[bubblewrap](https://github.com/containers/bubblewrap). 

instead of making a complex jail environment with many features, the goal here 
to have something simple that you can audit by hand very quickly. it is
currently < 300 loc of clean python.

## high level picture

ajail is a bubblewrapped chroot. you store the immutable root filesystem named 
`name` in `~/.ajail/fs/name`.

when you run `ajail --fs=name <command>` in a folder, a bubblewrapped, chrooted 
environment is started with the root filesystem named `name`, with the current
directory mounted inside. the root fs is mounted read only with a read/write
temporary overlay fs, and the current directory is mounted read/write or read 
only with a temporary overlay fs, depending on your arguments.

inside the bubblewrapped, chrooted environment, your UID/GID are mapped to
appear as root through the magic of linux namespacing. inside the jail,
everything appears root owned, and processes appear to have root privileges. in
reality, they only have access to what you've allowed them to have, and root
operations inside the jail appear as your UID outside the jail.

the key feature this combo of things provides is that inside the jail, system
packages can be installed ephemerally. `apk add nodejs` will install `nodejs`
but it will disappear next session. the same applies to changes to `$HOME`.

note that inside the jail, `$HOME` is `/root`, which can be found (and persisted
with `--fs-edit`) at `~/.ajail/fs/<name>/root`.

## cloning

one special feature is `--clone`, which, if run inside a folder that is a source
repository (e.g. a Git repo), instead of mounting it directly will make a clone
with the current directory as the upstream, and mount that instead. this is
extremely useful for running multiple AI agents concurrently.

## setup

ajail comes with two scripts, mkalpine.sh and mkdeb.sh. both scripts create
a rootfs in the given target folder. you use them like

```
sudo ./mkalpine.sh -u $(whoami) ~/.ajail/fs/alpine -p nano
```

or

```
sudo ./mkdeb.sh -u $(whoami) ~/.ajail/fs/deb -p vim,build-essential
```

ajail does not create a full user id namespace, but instead just maps your uid
to root. because of this, there are no users other than root inside the jail.
this makes `apt` and `dpkg` kind of mad, so Debian based rootfses need all 
packages preinstalled. `apk` handles this better, so packages can be temporarily
installed inside of an alpine jail.

for a basic setup, run

```
sudo ./mkalpine.sh -u $(whoami) ~/.ajail/fs/default -p \
  bash,build-base,alpine-sdk,go,python3,py3-pip,nodejs,npm,wget,curl,git
```

## usage

```
ajail - a simple script to make using bubblewrap in a folder easier.

usage: ajail [OPTION]... [<COMMAND>...]

 --fs=<ROOT_FS>           specify the root fs to use. by default uses 'default'.
                          if ROOT_FS is not an absolute path, the name is looked
                          for at ~/.ajail/fs/<ROOT_FS>.
 --ro                     wrap the current working directory in a temporary
                          overlay.
 --ro=<SUBDIR>            wrap the provided subdirectory in a temporary overlay.
 --rw=<SUBDIR>            make changes to the provided subdirectory persistent.
 --hide=<SUBDIR>          make the provided subdirectory appear empty.
 --mount=<SRC>,<DST>[,rw] mount SRC at DST. mounted with a temporary overlay
                          unless rw is provided for persistence.
 --fs-edit                make changes to the root filesystem persistent.
 --no-net                 disable network access.
 --clone                  if the current directory is a source repository,
                          instead of mounting the current directory directly,
                          we will make a new clone of the source repository
                          with the source directory as the upstream repo and
                          mount that. pushing from inside will update the
                          current directory's metadata.

if [<command>...] is not provided, defaults to 'sh'.
```

here is how to run a command (`sh`) in the default rootfs with the current
directory mounted read/write:

```
ajail sh
```

* to use another rootfs, specify `--fs=fsname` before the command.
* to make changes to the current directory ephemeral, add `--ro` before the
  command. note that `--ro` does not mean the directory will be read-only
  inside the jail, but it does mean changes won't make it outside of the
  jail. from the perspective of the outside of the jail, the jail will
  only read the folder.
* to mount just a subdirectory , such as `.git`, add `--ro=.git` before
  the command. multiple `--ro=` arguments and `--rw=` arguments can be provided,
  processed in the order they are received. `--ro=` means the subdirectory
  will be ephemeral, `--rw=` means the subdirectory will be persistent.
  layering `--rw=` on top of an `--ro=` path allows you to punch a persistent
  hole in an otherwise ephemeral place.
* to make a directory appear empty (hide git history or something) you can do
  `--hide=dir`, like `--hide=.git`.
* `--ro=`, `--rw=` are both just special forms of `--mount`.
* if you want to mount the rootfs so you can make persistent changes to it,
  you can add `--fs-edit`
* you can disallow network access using `--no-net`

## example:

this will run claude code in the current directory without write access to
`./.git`:

```
ajail --ro=.git claude
```

(note that you will need to install and configure claude with `--fs-edit`
once first)

this will install vim into an alpine based rootfs:

```
ajail --fs-edit apk add vim
```

## LLM disclaimer:

ajail is human-written (but with light advice and suggestions from an LLM).
mkalpine.sh and mkdeb.sh were created with the help of an LLM.

## requirements:

* linux kernel >= 5.13 (overlayfs in user namespaces)
* python >= 3.9
* [bubblewrap](https://github.com/containers/bubblewrap) >= 0.11.0
  (`sudo dnf install bubblewrap` or `sudo apt install bubblewrap`)

* debootstrap for `mkdeb.sh`

## license

MIT
