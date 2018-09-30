# module related operations
{ lib
, callPackage
, runCommand
, glibcLocales
, haskellPackages
}:

with (callPackage ./files.nix {});

rec {
  # Turns a module name to a file
  moduleToFile = mod:
    (builtins.replaceStrings ["."] ["/"] mod) + ".hs";

  # Turns a module name into the filepath of its object file
  # TODO: bad name, this is module _name_ to object
  moduleToObject = mod:
    (builtins.replaceStrings ["."] ["/"] mod) + ".o";

  stripHs = lib.strings.removeSuffix ".hs";
  # Turns a filepath name to a module name
  fileToModule = file:
    stripHs
      (builtins.replaceStrings ["/"] ["."] file);

  # Singles out a given module (by module name) (derivation)
  singleOutModule = base: mod: singleOut base (moduleToFile mod);

  # Singles out a given module (by module name) (path to module file)
  singleOutModulePath = base: mod:
    "${singleOutModule base mod}/${moduleToFile mod}";

  # Generate a list of haskell module names needed by the haskell file
  listModuleImports = base: modName: exts:
    builtins.fromJSON
     (builtins.readFile (listAllModuleImportsJSON base modName exts));

  # Whether the file is a Haskell module or not. It uses very simple
  # heuristics: If the file starts with a capital letter, then yes.
  isHaskellModuleFile = f:
    ! (builtins.isNull (builtins.match "[A-Z].*hs" f));

  listModulesInDir = dir:
    map fileToModule
      (lib.filter isHaskellModuleFile
      (listFilesInDir dir));

  doesModuleExist = baseByModuleName: modName:
    doesFileExist (baseByModuleName modName) (moduleToFile modName);

  # Lists all module dependencies, not limited to modules existing in this
  # project
  listAllModuleImportsJSON = base: modName: exts:
    let
      ghc = haskellPackages.ghcWithPackages (ps: [ ps.ghc ]);
      importParser = runCommand "import-parser"
        { buildInputs = [ ghc ];
      } "ghc -package ghc ${./Imports.hs} -o $out" ;
      ghcOpts = (map (x: "-X${x}") exts);
    # XXX: this command needs ghc in the environment so that it can call "ghc
    # --print-libdir"...
    in runCommand "dependencies-json-${modName}" {
      inherit ghcOpts;
      buildInputs = [ ghc glibcLocales haskellPackages.cpphs ];
      LANG="en_US.utf-8";
    } ''
      ${importParser} $ghcOpts -pgmP cpphs -optP --cpp ${singleOutModulePath base modName} > $out
    '';
}
