{ runCommand
, lib
, callPackage
, stdenv
, rsync
, symlinkJoin
}:

with (callPackage ./modules.nix {});
with (callPackage ./lib.nix {});
with (callPackage ./module-spec.nix {});

rec {

  # Returns an attribute set where the keys are all the built module names and
  # the values are the paths to the object files.
  # mainModSpec: a "main" module
  buildMain = ghcWith: mainModSpec:
    buildModulesRec ghcWith
      # XXX: the main modules need special handling regarding the object name
      {
        a."${mainModSpec.moduleName}" = mainModSpec;
        b."${mainModSpec.moduleName}" = "${buildModule ghcWith mainModSpec}/Main.o";
      }
      mainModSpec.moduleImports;

  # returns a attrset where the keys are the module names and the values are
  # the modules' object file path
  buildLibrary = ghcWith: modSpecs:
    buildModulesRec ghcWith { a = {}; b = {}; } modSpecs;

  linkMainModule = ghcWith: mod: # main module
    let
      objAttrs = buildMain ghcWith mod;
      objList = lib.attrsets.mapAttrsToList (x: y: y) objAttrs;
      deps = allTransitiveDeps [mod];
      ghc = ghcWith deps;
      ghcOptsArgs = lib.strings.escapeShellArgs mod.moduleGhcOpts;
      packageList = map (p: "-package ${p}") deps;
      relExePath = "bin/${lib.strings.toLower mod.moduleName}";
      drv = runCommand "linker" {}
        ''
          mkdir -p $out/bin
          ${ghc}/bin/ghc \
            ${lib.strings.escapeShellArgs packageList} \
            ${lib.strings.escapeShellArgs objList} \
            ${ghcOptsArgs} \
            -o $out/${relExePath}
        '';
    in
      {
        out = drv;
        relExePath = relExePath;
      };

  # Build the given modules (recursively) using the given accumulator to keep
  # track of which modules have been built already
  # XXX: doesn't work if several modules in the DAG have the same name
  buildModulesRec = ghcWith: empty: modSpecs: let
      flattenModNamesFold = {
        f = modSpec: {
          ${modSpec.moduleName} = modSpec;
        };
        elemLabel = mod: mod.moduleName;
        elemChildren = mod: mod.moduleImports;
        reduce = a: b: a // b;
        empty = empty.a;
      };
      allModules = builtins.attrValues (foldDAG flattenModNamesFold modSpecs);
    in foldDAG
    {
      f = mod: {
        "${mod.moduleName}" = "${mod.builtModule}/${moduleToObject mod.moduleName}";
      };
      elemLabel = mod: mod.moduleName;
      elemChildren = mod: [];
      reduce = a: b: a // b;
      empty = empty.b;
    }
    allModules;

  buildModule = ghcWith: modSpec:
    let
      ghc = ghcWith deps;
      deps = modSpec.allTransitiveDeps;
      exts = modSpec.moduleExtensions;
      ghcOpts = modSpec.moduleGhcOpts ++ (map (x: "-X${x}") exts);
      ghcOptsArgs = lib.strings.escapeShellArgs ghcOpts;
      objectName = modSpec.moduleName;
      builtDeps = map (modSpec: modSpec.builtModule) (allTransitiveImports [modSpec]);
      depsDirs = map (x: x + "/") builtDeps;
      base = modSpec.moduleBase;
      makeSymtree =
        if lib.lists.length depsDirs >= 1
        # TODO: symlink instead of copy
        then "rsync -r --chmod=D+w ${lib.strings.escapeShellArgs depsDirs} ."
        else "";
      makeSymModule =
        # TODO: symlink instead of copy
        "rsync -r ${singleOutModule base modSpec.moduleName}/ .";
      pred = file: path: type:
        let
          topLevel = (builtins.toString base) + "/";
          actual = (lib.strings.removePrefix topLevel path);
          expected = file;
      in
        (expected == actual) ||
        (type == "directory" && (lib.strings.hasPrefix actual expected));

      extraFiles = builtins.filterSource
        (p: t:
          lib.lists.length
            (
            let
              topLevel = (builtins.toString base) + "/";
              actual = lib.strings.removePrefix topLevel p;
            in
              lib.filter (expected:
                (expected == actual) ||
                (t == "directory" && (lib.strings.hasPrefix actual expected))
                )
                modSpec.moduleFiles
            ) >= 1
        ) base;
      joinedSrc = symlinkJoin {
        name = "extra-files";
        paths = [ extraFiles ] ++ modSpec.moduleDirectories;
      };
      src' = if builtins.length ([ extraFiles ] ++ modSpec.moduleDirectories) == 1 then builtins.head ([ extraFiles ] ++ modSpec.moduleDirectories) else joinedSrc;
    in stdenv.mkDerivation {
      name = objectName;
      src = src';
      phases =
        [ "unpackPhase" "buildPhase" ];

      imports = map (mmm: mmm.moduleName) modSpec.moduleImports;
      buildPhase =
        ''
          echo "Building module ${modSpec.moduleName}"
          echo "Local imports are:"
          for foo in $imports; do
            echo " - $foo"
          done

          mkdir -p $out
          echo "Creating dependencies symtree for module ${modSpec.moduleName}"
          ${makeSymtree}
          echo "Creating module symlink for module ${modSpec.moduleName}"
          ${makeSymModule}
          if [ -f Pos/Util/CompileInfoGit.o ]; then
            mkdir -pv $out/Pos/Util
            cp -v Pos/Util/CompileInfoGit.{o,dyn_o} $out/Pos/Util
          fi
          if [ -f Pos/Binary/Class/TH.o ]; then
            mkdir -pv $out/Pos/Binary/Class
            cp -v Pos/Binary/Class/TH.{o,dyn_o} $out/Pos/Binary/Class
          fi
          if [ -f Pos/Binary/Class/Core.o ]; then
            mkdir -pv $out/Pos/Binary/Class
            cp -v Pos/Binary/Class/Core.{o,dyn_o} $out/Pos/Binary/Class
          fi
          echo "Compiling module ${modSpec.moduleName}"
          # Set a tmpdir we have control over, otherwise GHC fails, not sure why
          mkdir -p tmp
          ghc -tmpdir tmp/ ${moduleToFile modSpec.moduleName} -c \
            -outputdir $out \
            -dynamic-too \
            ${ghcOptsArgs} \
            2>&1

          ls $out
          echo "Done building module ${modSpec.moduleName}"
        '';

      buildInputs =
        [ ghc
          rsync
        ];
    };
}
