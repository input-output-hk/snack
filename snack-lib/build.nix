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
  buildMain = mainModSpec:
    buildModulesRec
      # XXX: the main modules need special handling regarding the object name
      {
        a."${mainModSpec.moduleName}" = mainModSpec;
        b."${mainModSpec.moduleName}" = "${buildModule mainModSpec}/Main.o";
      }
      mainModSpec.moduleImports;

  # returns a attrset where the keys are the module names and the values are
  # the modules' object file path
  buildLibrary = modSpecs:
    buildModulesRec { a = {}; b = {}; } modSpecs;

  linkMainModule = ghcWith: mod: # main module
    let
      objAttrs = buildMain mod;
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
  buildModulesRec = empty: modSpecs: let
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

  buildModule = modSpec:
    let
      ghcOptsArgs = lib.strings.escapeShellArgs (modSpec.moduleGhcOpts ++ (map (x: "-X${x}") modSpec.moduleExtensions));
      makeSymtree = if lib.lists.length modSpec.builtDeps >= 1 then
        let
          depsDirs = map (x: x + "/") modSpec.builtDeps;
        in
          # TODO: symlink instead of copy
          "rsync -r --chmod=D+w ${lib.strings.escapeShellArgs depsDirs} ."
      else "";
      # TODO: symlink instead of copy
      makeSymModule = "rsync -r ${singleOutModule modSpec.moduleBase modSpec.moduleName}/ .";
      pred = file: path: type:
        let
          topLevel = (builtins.toString modSpec.moduleBase) + "/";
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
              topLevel = (builtins.toString modSpec.moduleBase) + "/";
              actual = lib.strings.removePrefix topLevel p;
            in
              lib.filter (expected:
                (expected == actual) ||
                (t == "directory" && (lib.strings.hasPrefix actual expected))
                )
                modSpec.moduleFiles
            ) >= 1
        ) modSpec.moduleBase;
      joinedSrc = symlinkJoin {
        name = "extra-files";
        paths = [ extraFiles ] ++ modSpec.moduleDirectories;
      };
      src' = if builtins.length ([ extraFiles ] ++ modSpec.moduleDirectories) == 1 then builtins.head ([ extraFiles ] ++ modSpec.moduleDirectories) else joinedSrc;
    in stdenv.mkDerivation {
      name = modSpec.moduleName;
      src = src';
      phases = [ "unpackPhase" "buildPhase" ];

      buildPhase = ''
          echo "Building module ${modSpec.moduleName}"

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

      buildInputs = [ modSpec.ghcWithDeps rsync ];
    };
}
