# Functions related to module specs
{ lib
, callPackage
}:

with (callPackage ./modules.nix {});
with (callPackage ./package-spec.nix {});
with (callPackage ./lib.nix {});
with (callPackage ./build.nix {});

rec {
  makeModuleSpec = { modName, modImports, modFiles, modDirs, modBase, modDeps, modExts, modGhcOpts, ghcWith }:
  let
    self = {
      moduleName = modName;

      # local module imports, i.e. not part of an external dependency
      moduleImports = modImports;

      moduleFiles = modFiles;
      moduleDirectories = modDirs;
      moduleBase = modBase;
      moduleDependencies =
        if builtins.isList modDeps
        then modDeps
        else abort "module dependencies should be a list";
      moduleGhcOpts = modGhcOpts;
      moduleExtensions = modExts;
      allTransitiveDeps = allTransitiveDeps [ self ];
      builtModule = buildModule ghcWith self;
    };
  in self;


    moduleSpecFold =
      { baseByModuleName
      , getInfoByModName
      , ghcWith
      }:
      result:
    let
      modImportsNames = modName:
        lib.lists.filter
          (modName': ! builtins.isNull (baseByModuleName modName'))
          (listModuleImports baseByModuleName modName);
    in
      # TODO: DFS instead of Fold
      {
        f = modName: let info = getInfoByModName modName; in {
          "${modName}" = makeModuleSpec {
            inherit modName ghcWith;
            modImports = map (mn: result.${mn}) (modImportsNames modName);
            modFiles = info.files;
            modDirs = info.dirs;
            modBase = baseByModuleName modName;
            modDeps = info.deps;
            modExts = info.exts;
            modGhcOpts = info.ghcOpts;
          };
        };
        empty = {} ;
        reduce = a: b: a // b;
        elemLabel = lib.id;
        elemChildren = modName: modImportsNames modName;
      };

  # Returns a list of all modules in the module spec graph
  flattenModuleSpec = modSpec:
    [ modSpec ] ++
      ( lib.lists.concatMap flattenModuleSpec modSpec.moduleImports );

  allTransitiveDeps = allTransitiveLists "moduleDependencies";
  allTransitiveGhcOpts = allTransitiveLists "moduleGhcOpts";
  allTransitiveExtensions = allTransitiveLists "moduleExtensions";
  allTransitiveDirectories = allTransitiveLists "moduleDirectories";
  allTransitiveImports = allTransitiveLists "moduleImports";

  allTransitiveLists = attr: modSpecs:
    lib.lists.unique
    (
    foldDAG
      { f = modSpec:
          lib.lists.foldl
            (x: y: x ++ [y])
            [] modSpec.${attr};
        empty = [];
        elemLabel = modSpec: modSpec.moduleName;
        reduce = a: b: a ++ b;
        elemChildren = modSpec: modSpec.moduleImports;
      }
      modSpecs
    )
      ;

  # Takes a package spec and returns (modSpecs -> Fold)
  modSpecFoldFromPackageSpec = ghcWith: pkgSpec:
      let
        partial = pkgSpecByModuleName pkgSpec;
        baseByModuleName = modName:
          let res = partial null modName;
          in if res == null then null else res.packageBase;
        partial2 = partial (abort "error near partial2");
        getInfoByModName = modName: let
          spec = partial2 modName;
        in {
          files = pkgSpec.packageExtraFiles modName;
          deps = spec.packageDependencies modName;
          exts = spec.packageExtensions;
          ghcOpts = spec.packageGhcOpts;
          dirs = spec.packageExtraDirectories modName;
        };
      in
      moduleSpecFold {
        inherit getInfoByModName ghcWith;
        baseByModuleName = baseByModuleName;
      };

}
