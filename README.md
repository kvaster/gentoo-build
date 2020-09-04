# Gentoo image builder

_README is in progress. Thank you for understanding._

## Intro

As for me, gentoo is really good and flexible linux, but when you need to deploy it to 100
and more servers - you need a build server.

This project is an example scripts for such build server.

There will be three results of the build process:
* New (latest, optimized) stage3 tarball
* New stage4 taraball - this image can be deployed with minimal configuration on real server
* Binary packages for different software we may need later for different setups.

## Current quircks/hacks (to be removed when resolved)

* gcc on rpi can't be built with lto enabled - lto is turned off for now
* llvm on goldmont-plus can't be built with native optimization - core2 optimizations are used for llvm on goldmont-plus

## My gentoo preferences

* First of all I'm always using 'latest' packages ('unstable' gentoo). Theese are `~amd64` and `~arm64` keywords.
While it is called 'unstable' it is really more stable when stable ubuntu from my point of view.
* I'm using custom optimizations for different amd64 arches (broadwell, skylake, zen2, e.t.c.).

## Prerequisite

In order to deploy and update images we need running at least to services:
* rsync service to sync portage tree - we need to have it the same on our severs as it was be while we were building new images and binary packages
* http service to provide access to binary packages repository

I'm using `/var/lib/gentoo-build` as a root for binary packages, tarballs and portage tree.
Example config files:
* rsync: [rsyncd.conf](rsyncd.conf)
* nginx: [nginx-gentoo.conf](nginx-gentoo.conf)

It is supposed that we're serving rsync and nginx on gentoo.example.com (this is an config option in config.yml)

## Basic config

Build script is searching for config files in `config` folder relative to `build.rb` folder.
Also script will merge default `config.yml` with `config.user.yml` if it will be located in current directory.
It means that for basic setup you may just create `config.user.yml` in current folder with following content:

```
repository_domain: gentoo.mydomain.com
```

## Using build script

### sync

Before we can build something we should create/update portage tree (and overlays data).
For this we can use sync command:

```./build.rb sync```

### build

Build means BUILD! Build will always process from scratch, but will use binary packages and stage3 tarball from previous run.

_For the first build we need to download latest stage3 tarball from gentoo download site and place it under `/var/lib/gentoo-build/release/stage3-ARCH-latest.tar.xz` (extension may differ)._

```./build.rb -a ARCH build```

`ARCH` may be:
* Concrete arch name (in default config.yml: broadwell, generic ...).
* List of arch names comma separated (i.e. broadwell,generic ...).
* Group name (in default config.yml: amd64 or arm64).
* `all` to build all arches defined in config.yml

### apply

All build artifacts are not transfered to 'repository' folder by default. You should run 'apply' command for that:

```./build.rb apply -a ARCH```

This command will transfer stage3 and stage4 tarballs to release folder and will sync binary packages to arch packages folder.

_You may use `-A` or `--apply` switch to automatically apply all built arches in `build` command._

`tmp` folder is kept after build and you can chroot to it and emerge/reemerge other packages. After that you can run `apply` once more.

### delpkg

Sometimes you need some packages to be rebuilt. In this case you should be sure that there is no binary package for it. You may use `delpkg` command for this:

```./build.rb -a all delpkg 'sys-cluster/kubeadm'```

or

```./build.rb -a all delpkg '*/kubeadm'```
