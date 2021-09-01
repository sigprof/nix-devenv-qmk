{ avr ? true, arm ? true, riscv32 ? true, teensy ? true }:
let
  # We specify sources via Niv: use "niv update nixpkgs" to update nixpkgs, for example.
  sources = import ./nix/sources.nix { };
  pkgs = import sources.nixpkgs { };

  poetry2nix = pkgs.callPackage (import sources.poetry2nix) { };

  # Builds the python env based on nix/pyproject.toml and
  # nix/poetry.lock Use the "poetry update --lock", "poetry add
  # --lock" etc. in the nix folder to adjust the contents of those
  # files if the requirements*.txt files change
  pythonEnv = poetry2nix.mkPoetryEnv {
    projectDir = ./nix;
    overrides = poetry2nix.overrides.withDefaults (self: super: {
      qmk = super.qmk.overridePythonAttrs(old: {
        # Allow QMK CLI to run "bin/qmk" as a subprocess (the wrapper changes
        # $PATH and breaks these invocations).
        dontWrapPythonPrograms = true;
      });
    });
  };
in

with pkgs;
let
  avrlibc = pkgsCross.avr.libcCross;

  avr_incflags = [
    "-isystem ${avrlibc}/avr/include"
    "-B${avrlibc}/avr/lib/avr5"
    "-L${avrlibc}/avr/lib/avr5"
    "-B${avrlibc}/avr/lib/avr35"
    "-L${avrlibc}/avr/lib/avr35"
    "-B${avrlibc}/avr/lib/avr51"
    "-L${avrlibc}/avr/lib/avr51"
  ];

  # Platform definition which explicitly specifies the `arch` and `abi` values
  # that are needed for GD32VF103 (which is the only RISC-V chip supported in
  # QMK at the moment).  Without those values GCC assumes that the core
  # supports hardware floating point, and uses the hard-float ABI when
  # compiling newlib, then those newlib files cannot be linked with QMK object
  # files compiled for the soft-float ABI.
  #
  riscv32-embedded-rv32imac-ilp32 = {
    config = "riscv32-none-elf";
    libc = "newlib";
    gcc = {
      arch = "rv32imac";
      abi = "ilp32";
      #enableMultilib = true;
    };
  };

  # Attempt to enable multilib support in GCC, using the same `enableMultilib`
  # parameter as https://github.com/NixOS/nixpkgs/pull/111321 (but trying to do
  # it without patching the GCC packages).  Does not work, because the library
  # search path is not set properly (the above PR has the same unsolved issue).
  #
  #gccMultilibOverlay = final: prev: {
  #  gccFun = args: prev.gccFun (args // {
  #    enableMultilib = (args.stdenv or final.stdenv).targetPlatform.gcc.enableMultilib or false;
  #  });
  #  wrapCC = cc: prev.wrapCC (cc.override {
  #    enableMultilib = cc.stdenv.targetPlatform.gcc.enableMultilib or false;
  #  });
  #};

  # Replacement for `pkgs.pkgsCross.riscv32-embedded` which uses the custom
  # platform definition.
  #
  riscv32CrossPkgs = import sources.nixpkgs {
    localSystem = pkgs.stdenv.system;
    crossSystem = riscv32-embedded-rv32imac-ilp32;
    #overlays = [ gccMultilibOverlay ];
  };

in
mkShell {
  name = "qmk-firmware";

  buildInputs = [ clang-tools dfu-programmer dfu-util diffutils git pythonEnv poetry niv ]
    ++ lib.optional avr [
      pkgsCross.avr.buildPackages.binutils
      pkgsCross.avr.buildPackages.gcc8
      avrlibc
      avrdude
    ]
    ++ lib.optional arm [ gcc-arm-embedded ]
    ++ lib.optional riscv32 [
      riscv32CrossPkgs.buildPackages.binutils
      riscv32CrossPkgs.buildPackages.gcc
      riscv32CrossPkgs.libcCross
    ]
    ++ lib.optional teensy [ teensy-loader-cli ];

  AVR_CFLAGS = lib.optional avr avr_incflags;
  AVR_ASFLAGS = lib.optional avr avr_incflags;
  shellHook = ''
    # Prevent the avr-gcc wrapper from picking up host GCC flags
    # like -iframework, which is problematic on Darwin
    unset NIX_CFLAGS_COMPILE_FOR_TARGET
  '';
}
