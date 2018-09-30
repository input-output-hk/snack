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
      allTransitiveImports = allTransitiveImports [ self ];
      ghcWithDeps = ghcWith self.allTransitiveDeps;
      builtModule = buildModule self;
      builtDeps = map (modSpec: modSpec.builtModule) self.allTransitiveImports;
    };
  in self;


    moduleSpecFold =
      { getInfoByModName
      , ghcWith
      }:
      result:
    let
      modImportsNames = modName: let
      info = getInfoByModName modName;
      in
        lib.lists.filter
          (modName': ! builtins.isNull (getInfoByModName modName').base )
          (listModuleImports info.base modName info.exts);
    in
      # TODO: DFS instead of Fold
      {
        f = modName: let info = getInfoByModName modName; in {
          "${modName}" = makeModuleSpec {
            inherit modName ghcWith;
            modImports = map (mn: result.${mn}) (modImportsNames modName);
            modFiles = info.files;
            modDirs = info.dirs;
            modBase = info.base;
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
      foldDAG {
        f = modSpec: modSpec.${attr};
        empty = [];
        elemLabel = modSpec: modSpec.moduleName;
        reduce = a: b: a ++ b;
        elemChildren = modSpec: modSpec.moduleImports;
      }
      modSpecs
    );

  # Takes a package spec and returns (modSpecs -> Fold)
  modSpecFoldFromPackageSpec = ghcWith: pkgSpec:
      let
        partial = pkgSpecByModuleName pkgSpec null;
        getInfoByModName = modName: let
          spec = partial modName;
        in {
          base = if spec == null then null else spec.packageBase;
          files = pkgSpec.packageExtraFiles modName;
          deps = spec.packageDependencies modName;
          exts = spec.packageExtensions;
          ghcOpts = spec.packageGhcOpts;
          dirs = spec.packageExtraDirectories modName;
        };
      in
      moduleSpecFold {
        inherit getInfoByModName ghcWith;
      };

}
