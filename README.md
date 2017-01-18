A collection of various scripts and CLI tools made over the years.

## Installation
Put this directory anywhere in your $PATH. I use:

    git clone https://github.com/Firehed/bin ~/bin
    export PATH=$PATH:~/bin

Or just copy and paste the necessary scripts into your own collection

## Requirements

Most scripts require PHP 7.

## Usage

### nf
Generates a **n**ew PHP **f**ile with the namespacing, class name, and general
bolierplate auto-detected based on the directory and file name.

### git-switch
Light wrapper around `git branch` and `git checkout`, which allows you to
interactively select a branch to check out. Branches are sorted alphabetically
(with `master` always on top). Mostly saves you from typos in long branch names.
