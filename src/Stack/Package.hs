{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- | Dealing with Cabal.

module Stack.Package
  (readDotBuildinfo
  ,resolvePackage
  ,packageFromPackageDescription
  ,Package(..)
  ,PackageDescriptionPair(..)
  ,GetPackageFiles(..)
  ,GetPackageOpts(..)
  ,PackageConfig(..)
  ,buildLogPath
  ,PackageException (..)
  ,resolvePackageDescription
  ,packageDependencies
  ,mkLocalPackageView)
  where

import qualified Data.ByteString.Lazy.Char8 as CL8
import           Data.List (isSuffixOf, isPrefixOf, unzip)
import           Data.Maybe (maybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import           Distribution.Compiler
import           Distribution.ModuleName (ModuleName)
import qualified Distribution.ModuleName as Cabal
import qualified Distribution.Package as D
import           Distribution.Package hiding (Package,PackageName,packageName,packageVersion,PackageIdentifier)
import qualified Distribution.PackageDescription as D
import           Distribution.PackageDescription hiding (FlagName)
import           Distribution.PackageDescription.Parsec
import           Distribution.Simple.Utils
import           Distribution.System (OS (..), Arch, Platform (..))
import qualified Distribution.Text as D
import qualified Distribution.Types.CondTree as Cabal
import qualified Distribution.Types.ExeDependency as Cabal
import           Distribution.Types.ForeignLib
import qualified Distribution.Types.LegacyExeDependency as Cabal
import           Distribution.Types.MungedPackageName
import qualified Distribution.Types.UnqualComponentName as Cabal
import qualified Distribution.Verbosity as D
import           Distribution.Version (mkVersion)
import           Path as FL
import           Path.Extra
import           Path.IO hiding (findFiles)
import           Stack.Build.Installed
import           Stack.Constants
import           Stack.Constants.Config
import           Stack.Prelude hiding (Display (..))
import           Stack.PrettyPrint
import qualified Stack.PrettyPrint as PP (Style (Module))
import           Stack.Types.Build
import           Stack.Types.BuildPlan (ExeName (..))
import           Stack.Types.Compiler
import           Stack.Types.Config
import           Stack.Types.GhcPkgId
import           Stack.Types.NamedComponent
import           Stack.Types.Package
import           Stack.Types.Runner
import           Stack.Types.Version
import qualified System.Directory as D
import           System.FilePath (splitExtensions, replaceExtension)
import qualified System.FilePath as FilePath
import           System.IO.Error
import           RIO.Process

data Ctx = Ctx { ctxFile :: !(Path Abs File)
               , ctxDistDir :: !(Path Abs Dir)
               , ctxEnvConfig :: !EnvConfig
               }

instance HasPlatform Ctx
instance HasGHCVariant Ctx
instance HasLogFunc Ctx where
    logFuncL = configL.logFuncL
instance HasRunner Ctx where
    runnerL = configL.runnerL
instance HasConfig Ctx
instance HasPantryConfig Ctx where
    pantryConfigL = configL.pantryConfigL
instance HasProcessContext Ctx where
    processContextL = configL.processContextL
instance HasBuildConfig Ctx
instance HasEnvConfig Ctx where
    envConfigL = lens ctxEnvConfig (\x y -> x { ctxEnvConfig = y })

-- | Read @<package>.buildinfo@ ancillary files produced by some Setup.hs hooks.
-- The file includes Cabal file syntax to be merged into the package description
-- derived from the package's .cabal file.
--
-- NOTE: not to be confused with BuildInfo, an Stack-internal datatype.
readDotBuildinfo :: MonadIO m
                 => Path Abs File
                 -> m HookedBuildInfo
readDotBuildinfo buildinfofp =
    liftIO $ readHookedBuildInfo D.silent (toFilePath buildinfofp)

-- | Resolve a parsed cabal file into a 'Package', which contains all of
-- the info needed for stack to build the 'Package' given the current
-- configuration.
resolvePackage :: PackageConfig
               -> GenericPackageDescription
               -> Package
resolvePackage packageConfig gpkg =
    packageFromPackageDescription
        packageConfig
        (genPackageFlags gpkg)
        (resolvePackageDescription packageConfig gpkg)

packageFromPackageDescription :: PackageConfig
                              -> [D.Flag]
                              -> PackageDescriptionPair
                              -> Package
packageFromPackageDescription packageConfig pkgFlags (PackageDescriptionPair pkgNoMod pkg) =
    Package
    { packageName = name
    , packageVersion = pkgVersion pkgId
    , packageLicense = licenseRaw pkg
    , packageDeps = deps
    , packageFiles = pkgFiles
    , packageUnknownTools = unknownTools
    , packageGhcOptions = packageConfigGhcOptions packageConfig
    , packageFlags = packageConfigFlags packageConfig
    , packageDefaultFlags = M.fromList
      [(flagName flag, flagDefault flag) | flag <- pkgFlags]
    , packageAllDeps = S.fromList (M.keys deps)
    , packageLibraries =
        let mlib = do
              lib <- library pkg
              guard $ buildable $ libBuildInfo lib
              Just lib
         in
          case mlib of
            Nothing -> NoLibraries
            Just _ -> HasLibraries foreignLibNames
    , packageInternalLibraries = subLibNames
    , packageTests = M.fromList
      [(T.pack (Cabal.unUnqualComponentName $ testName t), testInterface t)
          | t <- testSuites pkgNoMod
          , buildable (testBuildInfo t)
      ]
    , packageBenchmarks = S.fromList
      [T.pack (Cabal.unUnqualComponentName $ benchmarkName b)
          | b <- benchmarks pkgNoMod
          , buildable (benchmarkBuildInfo b)
      ]
        -- Same comment about buildable applies here too.
    , packageExes = S.fromList
      [T.pack (Cabal.unUnqualComponentName $ exeName biBuildInfo)
        | biBuildInfo <- executables pkg
                                    , buildable (buildInfo biBuildInfo)]
    -- This is an action used to collect info needed for "stack ghci".
    -- This info isn't usually needed, so computation of it is deferred.
    , packageOpts = GetPackageOpts $
      \sourceMap installedMap omitPkgs addPkgs cabalfp ->
           do (componentsModules,componentFiles,_,_) <- getPackageFiles pkgFiles cabalfp
              let internals = S.toList $ internalLibComponents $ M.keysSet componentsModules
              excludedInternals <- mapM (parsePackageNameThrowing . T.unpack) internals
              mungedInternals <- mapM (parsePackageNameThrowing . T.unpack .
                                       toInternalPackageMungedName) internals
              componentsOpts <-
                  generatePkgDescOpts sourceMap installedMap
                  (excludedInternals ++ omitPkgs) (mungedInternals ++ addPkgs)
                  cabalfp pkg componentFiles
              return (componentsModules,componentFiles,componentsOpts)
    , packageHasExposedModules = maybe
          False
          (not . null . exposedModules)
          (library pkg)
    , packageBuildType = buildType pkg
    , packageSetupDeps = msetupDeps
    }
  where
    extraLibNames = S.union subLibNames foreignLibNames

    subLibNames
      = S.fromList
      $ map (T.pack . Cabal.unUnqualComponentName)
      $ mapMaybe libName -- this is a design bug in the Cabal API: this should statically be known to exist
      $ filter (buildable . libBuildInfo)
      $ subLibraries pkg

    foreignLibNames
      = S.fromList
      $ map (T.pack . Cabal.unUnqualComponentName . foreignLibName)
      $ filter (buildable . foreignLibBuildInfo)
      $ foreignLibs pkg

    toInternalPackageMungedName
      = T.pack . unMungedPackageName . computeCompatPackageName (pkgName pkgId)
      . Just . Cabal.mkUnqualComponentName . T.unpack

    -- Gets all of the modules, files, build files, and data files that
    -- constitute the package. This is primarily used for dirtiness
    -- checking during build, as well as use by "stack ghci"
    pkgFiles = GetPackageFiles $
        \cabalfp -> debugBracket ("getPackageFiles" <+> display cabalfp) $ do
             let pkgDir = parent cabalfp
             distDir <- distDirFromDir pkgDir
             env <- view envConfigL
             (componentModules,componentFiles,dataFiles',warnings) <-
                 runRIO
                     (Ctx cabalfp distDir env)
                     (packageDescModulesAndFiles pkg)
             setupFiles <-
                 if buildType pkg == Custom
                 then do
                     let setupHsPath = pkgDir </> relFileSetupHs
                         setupLhsPath = pkgDir </> relFileSetupLhs
                     setupHsExists <- doesFileExist setupHsPath
                     if setupHsExists then return (S.singleton setupHsPath) else do
                         setupLhsExists <- doesFileExist setupLhsPath
                         if setupLhsExists then return (S.singleton setupLhsPath) else return S.empty
                 else return S.empty
             buildFiles <- liftM (S.insert cabalfp . S.union setupFiles) $ do
                 let hpackPath = pkgDir </> relFileHpackPackageConfig
                 hpackExists <- doesFileExist hpackPath
                 return $ if hpackExists then S.singleton hpackPath else S.empty
             return (componentModules, componentFiles, buildFiles <> dataFiles', warnings)
    pkgId = package pkg
    name = pkgName pkgId

    (unknownTools, knownTools) = packageDescTools pkg

    deps = M.filterWithKey (const . not . isMe) (M.unionsWith (<>)
        [ asLibrary <$> packageDependencies packageConfig pkg
        -- We include all custom-setup deps - if present - in the
        -- package deps themselves. Stack always works with the
        -- invariant that there will be a single installed package
        -- relating to a package name, and this applies at the setup
        -- dependency level as well.
        , asLibrary <$> fromMaybe M.empty msetupDeps
        , knownTools
        ])
    msetupDeps = fmap
        (M.fromList . map (depName &&& depRange) . setupDepends)
        (setupBuildInfo pkg)

    asLibrary range = DepValue
      { dvVersionRange = range
      , dvType = AsLibrary
      }

    -- Is the package dependency mentioned here me: either the package
    -- name itself, or the name of one of the sub libraries
    isMe name' = name' == name || fromString (packageNameString name') `S.member` extraLibNames

-- | Generate GHC options for the package's components, and a list of
-- options which apply generally to the package, not one specific
-- component.
generatePkgDescOpts
    :: (HasEnvConfig env, MonadThrow m, MonadReader env m, MonadIO m)
    => SourceMap
    -> InstalledMap
    -> [PackageName] -- ^ Packages to omit from the "-package" / "-package-id" flags
    -> [PackageName] -- ^ Packages to add to the "-package" flags
    -> Path Abs File
    -> PackageDescription
    -> Map NamedComponent (Set DotCabalPath)
    -> m (Map NamedComponent BuildInfoOpts)
generatePkgDescOpts sourceMap installedMap omitPkgs addPkgs cabalfp pkg componentPaths = do
    config <- view configL
    cabalVer <- view cabalVersionL
    distDir <- distDirFromDir cabalDir
    let generate namedComponent binfo =
            ( namedComponent
            , generateBuildInfoOpts BioInput
                { biSourceMap = sourceMap
                , biInstalledMap = installedMap
                , biCabalDir = cabalDir
                , biDistDir = distDir
                , biOmitPackages = omitPkgs
                , biAddPackages = addPkgs
                , biBuildInfo = binfo
                , biDotCabalPaths = fromMaybe mempty (M.lookup namedComponent componentPaths)
                , biConfigLibDirs = configExtraLibDirs config
                , biConfigIncludeDirs = configExtraIncludeDirs config
                , biComponentName = namedComponent
                , biCabalVersion = cabalVer
                }
            )
    return
        ( M.fromList
              (concat
                   [ maybe
                         []
                         (return . generate CLib . libBuildInfo)
                         (library pkg)
                   , mapMaybe
                         (\sublib -> do
                            let maybeLib = CInternalLib . T.pack . Cabal.unUnqualComponentName <$> libName sublib
                            flip generate  (libBuildInfo sublib) <$> maybeLib
                          )
                         (subLibraries pkg)
                   , fmap
                         (\exe ->
                               generate
                                    (CExe (T.pack (Cabal.unUnqualComponentName (exeName exe))))
                                    (buildInfo exe))
                         (executables pkg)
                   , fmap
                         (\bench ->
                               generate
                                    (CBench (T.pack (Cabal.unUnqualComponentName (benchmarkName bench))))
                                    (benchmarkBuildInfo bench))
                         (benchmarks pkg)
                   , fmap
                         (\test ->
                               generate
                                    (CTest (T.pack (Cabal.unUnqualComponentName (testName test))))
                                    (testBuildInfo test))
                         (testSuites pkg)]))
  where
    cabalDir = parent cabalfp

-- | Input to 'generateBuildInfoOpts'
data BioInput = BioInput
    { biSourceMap :: !SourceMap
    , biInstalledMap :: !InstalledMap
    , biCabalDir :: !(Path Abs Dir)
    , biDistDir :: !(Path Abs Dir)
    , biOmitPackages :: ![PackageName]
    , biAddPackages :: ![PackageName]
    , biBuildInfo :: !BuildInfo
    , biDotCabalPaths :: !(Set DotCabalPath)
    , biConfigLibDirs :: !(Set FilePath)
    , biConfigIncludeDirs :: !(Set FilePath)
    , biComponentName :: !NamedComponent
    , biCabalVersion :: !Version
    }

-- | Generate GHC options for the target. Since Cabal also figures out
-- these options, currently this is only used for invoking GHCI (via
-- stack ghci).
generateBuildInfoOpts :: BioInput -> BuildInfoOpts
generateBuildInfoOpts BioInput {..} =
    BuildInfoOpts
        { bioOpts = ghcOpts ++ cppOptions biBuildInfo
        -- NOTE for future changes: Due to this use of nubOrd (and other uses
        -- downstream), these generated options must not rely on multiple
        -- argument sequences.  For example, ["--main-is", "Foo.hs", "--main-
        -- is", "Bar.hs"] would potentially break due to the duplicate
        -- "--main-is" being removed.
        --
        -- See https://github.com/commercialhaskell/stack/issues/1255
        , bioOneWordOpts = nubOrd $ concat
            [extOpts, srcOpts, includeOpts, libOpts, fworks, cObjectFiles]
        , bioPackageFlags = deps
        , bioCabalMacros = componentAutogen </> relFileCabalMacrosH
        }
  where
    cObjectFiles =
        mapMaybe (fmap toFilePath .
                  makeObjectFilePathFromC biCabalDir biComponentName biDistDir)
                 cfiles
    cfiles = mapMaybe dotCabalCFilePath (S.toList biDotCabalPaths)
    -- Generates: -package=base -package=base16-bytestring-0.1.1.6 ...
    deps =
        concat
            [ case M.lookup name biInstalledMap of
                Just (_, Stack.Types.Package.Library _ident ipid _) -> ["-package-id=" <> ghcPkgIdString ipid]
                _ -> ["-package=" <> packageNameString name <>
                 maybe "" -- This empty case applies to e.g. base.
                     ((("-" <>) . versionString) . piiVersion)
                     (M.lookup name biSourceMap)]
            | name <- pkgs]
    pkgs =
        biAddPackages ++
        [ name
        | Dependency name _ <- targetBuildDepends biBuildInfo
        , name `notElem` biOmitPackages]
    ghcOpts = concatMap snd . filter (isGhc . fst) $ options biBuildInfo
      where
        isGhc GHC = True
        isGhc _ = False
    extOpts = map (("-X" ++) . D.display) (usedExtensions biBuildInfo)
    srcOpts =
        map (("-i" <>) . toFilePathNoTrailingSep)
            (concat
              [ [ componentBuildDir biCabalVersion biComponentName biDistDir ]
              , [ biCabalDir
                | null (hsSourceDirs biBuildInfo)
                ]
              , mapMaybe toIncludeDir (hsSourceDirs biBuildInfo)
              , [ componentAutogen ]
              , maybeToList (packageAutogenDir biCabalVersion biDistDir)
              , [ componentOutputDir biComponentName biDistDir ]
              ]) ++
        [ "-stubdir=" ++ toFilePathNoTrailingSep (buildDir biDistDir) ]
    componentAutogen = componentAutogenDir biCabalVersion biComponentName biDistDir
    toIncludeDir "." = Just biCabalDir
    toIncludeDir relDir = concatAndColapseAbsDir biCabalDir relDir
    includeOpts =
        map ("-I" <>) (configExtraIncludeDirs <> pkgIncludeOpts)
    configExtraIncludeDirs = S.toList biConfigIncludeDirs
    pkgIncludeOpts =
        [ toFilePathNoTrailingSep absDir
        | dir <- includeDirs biBuildInfo
        , absDir <- handleDir dir
        ]
    libOpts =
        map ("-l" <>) (extraLibs biBuildInfo) <>
        map ("-L" <>) (configExtraLibDirs <> pkgLibDirs)
    configExtraLibDirs = S.toList biConfigLibDirs
    pkgLibDirs =
        [ toFilePathNoTrailingSep absDir
        | dir <- extraLibDirs biBuildInfo
        , absDir <- handleDir dir
        ]
    handleDir dir = case (parseAbsDir dir, parseRelDir dir) of
       (Just ab, _       ) -> [ab]
       (_      , Just rel) -> [biCabalDir </> rel]
       (Nothing, Nothing ) -> []
    fworks = map (\fwk -> "-framework=" <> fwk) (frameworks biBuildInfo)

-- | Make the .o path from the .c file path for a component. Example:
--
-- @
-- executable FOO
--   c-sources:        cbits/text_search.c
-- @
--
-- Produces
--
-- <dist-dir>/build/FOO/FOO-tmp/cbits/text_search.o
--
-- Example:
--
-- λ> makeObjectFilePathFromC
--     $(mkAbsDir "/Users/chris/Repos/hoogle")
--     CLib
--     $(mkAbsDir "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist")
--     $(mkAbsFile "/Users/chris/Repos/hoogle/cbits/text_search.c")
-- Just "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist/build/cbits/text_search.o"
-- λ> makeObjectFilePathFromC
--     $(mkAbsDir "/Users/chris/Repos/hoogle")
--     (CExe "hoogle")
--     $(mkAbsDir "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist")
--     $(mkAbsFile "/Users/chris/Repos/hoogle/cbits/text_search.c")
-- Just "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist/build/hoogle/hoogle-tmp/cbits/text_search.o"
-- λ>
makeObjectFilePathFromC
    :: MonadThrow m
    => Path Abs Dir          -- ^ The cabal directory.
    -> NamedComponent        -- ^ The name of the component.
    -> Path Abs Dir          -- ^ Dist directory.
    -> Path Abs File         -- ^ The path to the .c file.
    -> m (Path Abs File) -- ^ The path to the .o file for the component.
makeObjectFilePathFromC cabalDir namedComponent distDir cFilePath = do
    relCFilePath <- stripProperPrefix cabalDir cFilePath
    relOFilePath <-
        parseRelFile (replaceExtension (toFilePath relCFilePath) "o")
    return (componentOutputDir namedComponent distDir </> relOFilePath)

-- | Make the global autogen dir if Cabal version is new enough.
packageAutogenDir :: Version -> Path Abs Dir -> Maybe (Path Abs Dir)
packageAutogenDir cabalVer distDir
    | cabalVer < mkVersion [2, 0] = Nothing
    | otherwise = Just $ buildDir distDir </> relDirGlobalAutogen

-- | Make the autogen dir.
componentAutogenDir :: Version -> NamedComponent -> Path Abs Dir -> Path Abs Dir
componentAutogenDir cabalVer component distDir =
    componentBuildDir cabalVer component distDir </> relDirAutogen

-- | See 'Distribution.Simple.LocalBuildInfo.componentBuildDir'
componentBuildDir :: Version -> NamedComponent -> Path Abs Dir -> Path Abs Dir
componentBuildDir cabalVer component distDir
    | cabalVer < mkVersion [2, 0] = buildDir distDir
    | otherwise =
        case component of
            CLib -> buildDir distDir
            CInternalLib name -> buildDir distDir </> componentNameToDir name
            CExe name -> buildDir distDir </> componentNameToDir name
            CTest name -> buildDir distDir </> componentNameToDir name
            CBench name -> buildDir distDir </> componentNameToDir name

-- | The directory where generated files are put like .o or .hs (from .x files).
componentOutputDir :: NamedComponent -> Path Abs Dir -> Path Abs Dir
componentOutputDir namedComponent distDir =
    case namedComponent of
        CLib -> buildDir distDir
        CInternalLib name -> makeTmp name
        CExe name -> makeTmp name
        CTest name -> makeTmp name
        CBench name -> makeTmp name
  where
    makeTmp name =
      buildDir distDir </> componentNameToDir (name <> "/" <> name <> "-tmp")

-- | Make the build dir. Note that Cabal >= 2.0 uses the
-- 'componentBuildDir' above for some things.
buildDir :: Path Abs Dir -> Path Abs Dir
buildDir distDir = distDir </> relDirBuild

-- NOTE: don't export this, only use it for valid paths based on
-- component names.
componentNameToDir :: Text -> Path Rel Dir
componentNameToDir name =
  fromMaybe (error "Invariant violated: component names should always parse as directory names")
            (parseRelDir (T.unpack name))

-- | Get all dependencies of the package (buildable targets only).
--
-- Note that for Cabal versions 1.22 and earlier, there is a bug where
-- Cabal requires dependencies for non-buildable components to be
-- present. We're going to use GHC version as a proxy for Cabal
-- library version in this case for simplicity, so we'll check for GHC
-- being 7.10 or earlier. This obviously makes our function a lot more
-- fun to write...
packageDependencies
  :: PackageConfig
  -> PackageDescription
  -> Map PackageName VersionRange
packageDependencies pkgConfig pkg' =
  M.fromListWith intersectVersionRanges $
  map (depName &&& depRange) $
  concatMap targetBuildDepends (allBuildInfo' pkg) ++
  maybe [] setupDepends (setupBuildInfo pkg)
  where
    pkg
      | getGhcVersion (packageConfigCompilerVersion pkgConfig) >= mkVersion [8, 0] = pkg'
      -- Set all components to buildable. Only need to worry about
      -- library, exe, test, and bench, since others didn't exist in
      -- older Cabal versions
      | otherwise = pkg'
        { library = (\c -> c { libBuildInfo = go (libBuildInfo c) }) <$> library pkg'
        , executables = (\c -> c { buildInfo = go (buildInfo c) }) <$> executables pkg'
        , testSuites =
            if packageConfigEnableTests pkgConfig
              then (\c -> c { testBuildInfo = go (testBuildInfo c) }) <$> testSuites pkg'
              else testSuites pkg'
        , benchmarks =
            if packageConfigEnableBenchmarks pkgConfig
              then (\c -> c { benchmarkBuildInfo = go (benchmarkBuildInfo c) }) <$> benchmarks pkg'
              else benchmarks pkg'
        }

    go bi = bi { buildable = True }

-- | Get all dependencies of the package (buildable targets only).
--
-- This uses both the new 'buildToolDepends' and old 'buildTools'
-- information.
packageDescTools
  :: PackageDescription
  -> (Set ExeName, Map PackageName DepValue)
packageDescTools pd =
    (S.fromList $ concat unknowns, M.fromListWith (<>) $ concat knowns)
  where
    (unknowns, knowns) = unzip $ map perBI $ allBuildInfo' pd

    perBI :: BuildInfo -> ([ExeName], [(PackageName, DepValue)])
    perBI bi =
        (unknownTools, tools)
      where
        (unknownTools, knownTools) = partitionEithers $ map go1 (buildTools bi)

        tools = mapMaybe go2 (knownTools ++ buildToolDepends bi)

        -- This is similar to desugarBuildTool from Cabal, however it
        -- uses our own hard-coded map which drops tools shipped with
        -- GHC (like hsc2hs), and includes some tools from Stackage.
        go1 :: Cabal.LegacyExeDependency -> Either ExeName Cabal.ExeDependency
        go1 (Cabal.LegacyExeDependency name range) =
          case M.lookup name hardCodedMap of
            Just pkgName -> Right $ Cabal.ExeDependency pkgName (Cabal.mkUnqualComponentName name) range
            Nothing -> Left $ ExeName $ T.pack name

        go2 :: Cabal.ExeDependency -> Maybe (PackageName, DepValue)
        go2 (Cabal.ExeDependency pkg _name range)
          | pkg `S.member` preInstalledPackages = Nothing
          | otherwise = Just
              ( pkg
              , DepValue
                  { dvVersionRange = range
                  , dvType = AsBuildTool
                  }
              )

-- | A hard-coded map for tool dependencies
hardCodedMap :: Map String D.PackageName
hardCodedMap = M.fromList
  [ ("alex", Distribution.Package.mkPackageName "alex")
  , ("happy", Distribution.Package.mkPackageName "happy")
  , ("cpphs", Distribution.Package.mkPackageName "cpphs")
  , ("greencard", Distribution.Package.mkPackageName "greencard")
  , ("c2hs", Distribution.Package.mkPackageName "c2hs")
  , ("hscolour", Distribution.Package.mkPackageName "hscolour")
  , ("hspec-discover", Distribution.Package.mkPackageName "hspec-discover")
  , ("hsx2hs", Distribution.Package.mkPackageName "hsx2hs")
  , ("gtk2hsC2hs", Distribution.Package.mkPackageName "gtk2hs-buildtools")
  , ("gtk2hsHookGenerator", Distribution.Package.mkPackageName "gtk2hs-buildtools")
  , ("gtk2hsTypeGen", Distribution.Package.mkPackageName "gtk2hs-buildtools")
  ]

-- | Executable-only packages which come pre-installed with GHC and do
-- not need to be built. Without this exception, we would either end
-- up unnecessarily rebuilding these packages, or failing because the
-- packages do not appear in the Stackage snapshot.
preInstalledPackages :: Set D.PackageName
preInstalledPackages = S.fromList
  [ D.mkPackageName "hsc2hs"
  , D.mkPackageName "haddock"
  ]

-- | Variant of 'allBuildInfo' from Cabal that, like versions before
-- 2.2, only includes buildable components.
allBuildInfo' :: PackageDescription -> [BuildInfo]
allBuildInfo' pkg_descr = [ bi | lib <- allLibraries pkg_descr
                               , let bi = libBuildInfo lib
                               , buildable bi ]
                       ++ [ bi | flib <- foreignLibs pkg_descr
                               , let bi = foreignLibBuildInfo flib
                               , buildable bi ]
                       ++ [ bi | exe <- executables pkg_descr
                               , let bi = buildInfo exe
                               , buildable bi ]
                       ++ [ bi | tst <- testSuites pkg_descr
                               , let bi = testBuildInfo tst
                               , buildable bi ]
                       ++ [ bi | tst <- benchmarks pkg_descr
                               , let bi = benchmarkBuildInfo tst
                               , buildable bi ]

-- | Get all files referenced by the package.
packageDescModulesAndFiles
    :: PackageDescription
    -> RIO Ctx (Map NamedComponent (Map ModuleName (Path Abs File)), Map NamedComponent (Set DotCabalPath), Set (Path Abs File), [PackageWarning])
packageDescModulesAndFiles pkg = do
    (libraryMods,libDotCabalFiles,libWarnings) <-
        maybe
            (return (M.empty, M.empty, []))
            (asModuleAndFileMap libComponent libraryFiles)
            (library pkg)
    (subLibrariesMods,subLibDotCabalFiles,subLibWarnings) <-
        liftM
            foldTuples
            (mapM
                 (asModuleAndFileMap internalLibComponent libraryFiles)
                 (subLibraries pkg))
    (executableMods,exeDotCabalFiles,exeWarnings) <-
        liftM
            foldTuples
            (mapM
                 (asModuleAndFileMap exeComponent executableFiles)
                 (executables pkg))
    (testMods,testDotCabalFiles,testWarnings) <-
        liftM
            foldTuples
            (mapM (asModuleAndFileMap testComponent testFiles) (testSuites pkg))
    (benchModules,benchDotCabalPaths,benchWarnings) <-
        liftM
            foldTuples
            (mapM
                 (asModuleAndFileMap benchComponent benchmarkFiles)
                 (benchmarks pkg))
    dfiles <- resolveGlobFiles
                    (extraSrcFiles pkg
                        ++ map (dataDir pkg FilePath.</>) (dataFiles pkg))
    let modules = libraryMods <> subLibrariesMods <> executableMods <> testMods <> benchModules
        files =
            libDotCabalFiles <> subLibDotCabalFiles <> exeDotCabalFiles <> testDotCabalFiles <>
            benchDotCabalPaths
        warnings = libWarnings <> subLibWarnings <> exeWarnings <> testWarnings <> benchWarnings
    return (modules, files, dfiles, warnings)
  where
    libComponent = const CLib
    internalLibComponent = CInternalLib . T.pack . maybe "" Cabal.unUnqualComponentName . libName
    exeComponent = CExe . T.pack . Cabal.unUnqualComponentName . exeName
    testComponent = CTest . T.pack . Cabal.unUnqualComponentName . testName
    benchComponent = CBench . T.pack . Cabal.unUnqualComponentName . benchmarkName
    asModuleAndFileMap label f lib = do
        (a,b,c) <- f (label lib) lib
        return (M.singleton (label lib) a, M.singleton (label lib) b, c)
    foldTuples = foldl' (<>) (M.empty, M.empty, [])

-- | Resolve globbing of files (e.g. data files) to absolute paths.
resolveGlobFiles :: [String] -> RIO Ctx (Set (Path Abs File))
resolveGlobFiles =
    liftM (S.fromList . catMaybes . concat) .
    mapM resolve
  where
    resolve name =
        if '*' `elem` name
            then explode name
            else liftM return (resolveFileOrWarn name)
    explode name = do
        dir <- asks (parent . ctxFile)
        names <-
            matchDirFileGlob'
                (FL.toFilePath dir)
                name
        mapM resolveFileOrWarn names
    matchDirFileGlob' dir glob =
        catch
            (matchDirFileGlob_ dir glob)
            (\(e :: IOException) ->
                  if isUserError e
                      then do
                          prettyWarnL
                              [ flow "Wildcard does not match any files:"
                              , style File $ fromString glob
                              , line <> flow "in directory:"
                              , style Dir $ fromString dir
                              ]
                          return []
                      else throwIO e)

-- | This is a copy/paste of the Cabal library function, but with
--
-- @ext == ext'@
--
-- Changed to
--
-- @isSuffixOf ext ext'@
--
-- So that this will work:
--
-- @
-- λ> matchDirFileGlob_ "." "test/package-dump/*.txt"
-- ["test/package-dump/ghc-7.8.txt","test/package-dump/ghc-7.10.txt"]
-- @
--
matchDirFileGlob_ :: HasRunner env => String -> String -> RIO env [String]
matchDirFileGlob_ dir filepath = case parseFileGlob filepath of
  Nothing -> liftIO $ throwString $
      "invalid file glob '" ++ filepath
      ++ "'. Wildcards '*' are only allowed in place of the file"
      ++ " name, not in the directory name or file extension."
      ++ " If a wildcard is used it must be with an file extension."
  Just (NoGlob filepath') -> return [filepath']
  Just (FileGlob dir' ext) -> do
    efiles <- liftIO $ try $ D.getDirectoryContents (dir FilePath.</> dir')
    let matches =
            case efiles of
                Left (_ :: IOException) -> []
                Right files ->
                    [ dir' FilePath.</> file
                    | file <- files
                    , let (name, ext') = splitExtensions file
                    , not (null name) && isSuffixOf ext ext'
                    ]
    when (null matches) $
        prettyWarnL
            [ flow "filepath wildcard"
            , "'" <> style File (fromString filepath) <> "'"
            , flow "does not match any files."
            ]
    return matches

-- | Get all files referenced by the benchmark.
benchmarkFiles
    :: NamedComponent
    -> Benchmark
    -> RIO Ctx (Map ModuleName (Path Abs File), Set DotCabalPath, [PackageWarning])
benchmarkFiles component bench = do
    resolveComponentFiles component build names
  where
    names = bnames <> exposed
    exposed =
        case benchmarkInterface bench of
            BenchmarkExeV10 _ fp -> [DotCabalMain fp]
            BenchmarkUnsupported _ -> []
    bnames = map DotCabalModule (otherModules build)
    build = benchmarkBuildInfo bench

-- | Get all files referenced by the test.
testFiles
    :: NamedComponent
    -> TestSuite
    -> RIO Ctx (Map ModuleName (Path Abs File), Set DotCabalPath, [PackageWarning])
testFiles component test = do
    resolveComponentFiles component build names
  where
    names = bnames <> exposed
    exposed =
        case testInterface test of
            TestSuiteExeV10 _ fp -> [DotCabalMain fp]
            TestSuiteLibV09 _ mn -> [DotCabalModule mn]
            TestSuiteUnsupported _ -> []
    bnames = map DotCabalModule (otherModules build)
    build = testBuildInfo test

-- | Get all files referenced by the executable.
executableFiles
    :: NamedComponent
    -> Executable
    -> RIO Ctx (Map ModuleName (Path Abs File), Set DotCabalPath, [PackageWarning])
executableFiles component exe = do
    resolveComponentFiles component build names
  where
    build = buildInfo exe
    names =
        map DotCabalModule (otherModules build) ++
        [DotCabalMain (modulePath exe)]

-- | Get all files referenced by the library.
libraryFiles
    :: NamedComponent
    -> Library
    -> RIO Ctx (Map ModuleName (Path Abs File), Set DotCabalPath, [PackageWarning])
libraryFiles component lib = do
    resolveComponentFiles component build names
  where
    build = libBuildInfo lib
    names = bnames ++ exposed
    exposed = map DotCabalModule (exposedModules lib)
    bnames = map DotCabalModule (otherModules build)

-- | Get all files referenced by the component.
resolveComponentFiles
    :: NamedComponent
    -> BuildInfo
    -> [DotCabalDescriptor]
    -> RIO Ctx (Map ModuleName (Path Abs File), Set DotCabalPath, [PackageWarning])
resolveComponentFiles component build names = do
    dirs <- mapMaybeM resolveDirOrWarn (hsSourceDirs build)
    dir <- asks (parent . ctxFile)
    (modules,files,warnings) <-
        resolveFilesAndDeps
            component
            (if null dirs then [dir] else dirs)
            names
    cfiles <- buildOtherSources build
    return (modules, files <> cfiles, warnings)

-- | Get all C sources and extra source files in a build.
buildOtherSources :: BuildInfo -> RIO Ctx (Set DotCabalPath)
buildOtherSources build =
    do csources <- liftM
                       (S.map DotCabalCFilePath . S.fromList)
                       (mapMaybeM resolveFileOrWarn (cSources build))
       jsources <- liftM
                       (S.map DotCabalFilePath . S.fromList)
                       (mapMaybeM resolveFileOrWarn (targetJsSources build))
       return (csources <> jsources)

-- | Get the target's JS sources.
targetJsSources :: BuildInfo -> [FilePath]
targetJsSources = jsSources

-- | A pair of package descriptions: one which modified the buildable
-- values of test suites and benchmarks depending on whether they are
-- enabled, and one which does not.
--
-- Fields are intentionally lazy, we may only need one or the other
-- value.
--
-- MSS 2017-08-29: The very presence of this data type is terribly
-- ugly, it represents the fact that the Cabal 2.0 upgrade did _not_
-- go well. Specifically, we used to have a field to indicate whether
-- a component was enabled in addition to buildable, but that's gone
-- now, and this is an ugly proxy. We should at some point clean up
-- the mess of Package, LocalPackage, etc, and probably pull in the
-- definition of PackageDescription from Cabal with our additionally
-- needed metadata. But this is a good enough hack for the
-- moment. Odds are, you're reading this in the year 2024 and thinking
-- "wtf?"
data PackageDescriptionPair = PackageDescriptionPair
  { pdpOrigBuildable :: PackageDescription
  , pdpModifiedBuildable :: PackageDescription
  }

-- | Evaluates the conditions of a 'GenericPackageDescription', yielding
-- a resolved 'PackageDescription'.
resolvePackageDescription :: PackageConfig
                          -> GenericPackageDescription
                          -> PackageDescriptionPair
resolvePackageDescription packageConfig (GenericPackageDescription desc defaultFlags mlib subLibs foreignLibs' exes tests benches) =
    PackageDescriptionPair
      { pdpOrigBuildable = go False
      , pdpModifiedBuildable = go True
      }
  where
        go modBuildable =
          desc {library =
                  fmap (resolveConditions rc updateLibDeps) mlib
               ,subLibraries =
                  map (\(n, v) -> (resolveConditions rc updateLibDeps v){libName=Just n})
                      subLibs
               ,foreignLibs =
                  map (\(n, v) -> (resolveConditions rc updateForeignLibDeps v){foreignLibName=n})
                      foreignLibs'
               ,executables =
                  map (\(n, v) -> (resolveConditions rc updateExeDeps v){exeName=n})
                      exes
               ,testSuites =
                  map (\(n,v) -> (resolveConditions rc (updateTestDeps modBuildable) v){testName=n})
                      tests
               ,benchmarks =
                  map (\(n,v) -> (resolveConditions rc (updateBenchmarkDeps modBuildable) v){benchmarkName=n})
                      benches}

        flags =
          M.union (packageConfigFlags packageConfig)
                  (flagMap defaultFlags)

        rc = mkResolveConditions
                (packageConfigCompilerVersion packageConfig)
                (packageConfigPlatform packageConfig)
                flags

        updateLibDeps lib deps =
          lib {libBuildInfo =
                 (libBuildInfo lib) {targetBuildDepends = deps}}
        updateForeignLibDeps lib deps =
          lib {foreignLibBuildInfo =
                 (foreignLibBuildInfo lib) {targetBuildDepends = deps}}
        updateExeDeps exe deps =
          exe {buildInfo =
                 (buildInfo exe) {targetBuildDepends = deps}}

        -- Note that, prior to moving to Cabal 2.0, we would set
        -- testEnabled/benchmarkEnabled here. These fields no longer
        -- exist, so we modify buildable instead here.  The only
        -- wrinkle in the Cabal 2.0 story is
        -- https://github.com/haskell/cabal/issues/1725, where older
        -- versions of Cabal (which may be used for actually building
        -- code) don't properly exclude build-depends for
        -- non-buildable components. Testing indicates that everything
        -- is working fine, and that this comment can be completely
        -- ignored. I'm leaving the comment anyway in case something
        -- breaks and you, poor reader, are investigating.
        updateTestDeps modBuildable test deps =
          let bi = testBuildInfo test
              bi' = bi
                { targetBuildDepends = deps
                , buildable = buildable bi && (if modBuildable then packageConfigEnableTests packageConfig else True)
                }
           in test { testBuildInfo = bi' }
        updateBenchmarkDeps modBuildable benchmark deps =
          let bi = benchmarkBuildInfo benchmark
              bi' = bi
                { targetBuildDepends = deps
                , buildable = buildable bi && (if modBuildable then packageConfigEnableBenchmarks packageConfig else True)
                }
           in benchmark { benchmarkBuildInfo = bi' }

-- | Make a map from a list of flag specifications.
--
-- What is @flagManual@ for?
flagMap :: [Flag] -> Map FlagName Bool
flagMap = M.fromList . map pair
  where pair :: Flag -> (FlagName, Bool)
        pair = flagName &&& flagDefault

data ResolveConditions = ResolveConditions
    { rcFlags :: Map FlagName Bool
    , rcCompilerVersion :: ActualCompiler
    , rcOS :: OS
    , rcArch :: Arch
    }

-- | Generic a @ResolveConditions@ using sensible defaults.
mkResolveConditions :: ActualCompiler -- ^ Compiler version
                    -> Platform -- ^ installation target platform
                    -> Map FlagName Bool -- ^ enabled flags
                    -> ResolveConditions
mkResolveConditions compilerVersion (Platform arch os) flags = ResolveConditions
    { rcFlags = flags
    , rcCompilerVersion = compilerVersion
    , rcOS = os
    , rcArch = arch
    }

-- | Resolve the condition tree for the library.
resolveConditions :: (Semigroup target,Monoid target,Show target)
                  => ResolveConditions
                  -> (target -> cs -> target)
                  -> CondTree ConfVar cs target
                  -> target
resolveConditions rc addDeps (CondNode lib deps cs) = basic <> children
  where basic = addDeps lib deps
        children = mconcat (map apply cs)
          where apply (Cabal.CondBranch cond node mcs) =
                  if condSatisfied cond
                     then resolveConditions rc addDeps node
                     else maybe mempty (resolveConditions rc addDeps) mcs
                condSatisfied c =
                  case c of
                    Var v -> varSatisifed v
                    Lit b -> b
                    CNot c' ->
                      not (condSatisfied c')
                    COr cx cy ->
                      condSatisfied cx || condSatisfied cy
                    CAnd cx cy ->
                      condSatisfied cx && condSatisfied cy
                varSatisifed v =
                  case v of
                    OS os -> os == rcOS rc
                    Arch arch -> arch == rcArch rc
                    Flag flag ->
                      fromMaybe False $ M.lookup flag (rcFlags rc)
                      -- NOTE:  ^^^^^ This should never happen, as all flags
                      -- which are used must be declared. Defaulting to
                      -- False.
                    Impl flavor range ->
                      case (flavor, rcCompilerVersion rc) of
                        (GHC, ACGhc vghc) -> vghc `withinRange` range
                        (GHC, ACGhcjs _ vghc) -> vghc `withinRange` range
                        (GHCJS, ACGhcjs vghcjs _) ->
                          vghcjs `withinRange` range
                        _ -> False

-- | Get the name of a dependency.
depName :: Dependency -> PackageName
depName (Dependency n _) = n

-- | Get the version range of a dependency.
depRange :: Dependency -> VersionRange
depRange (Dependency _ r) = r

-- | Try to resolve the list of base names in the given directory by
-- looking for unique instances of base names applied with the given
-- extensions, plus find any of their module and TemplateHaskell
-- dependencies.
resolveFilesAndDeps
    :: NamedComponent       -- ^ Package component name
    -> [Path Abs Dir]       -- ^ Directories to look in.
    -> [DotCabalDescriptor] -- ^ Base names.
    -> RIO Ctx (Map ModuleName (Path Abs File),Set DotCabalPath,[PackageWarning])
resolveFilesAndDeps component dirs names0 = do
    (dotCabalPaths, foundModules, missingModules) <- loop names0 S.empty
    warnings <- liftM2 (++) (warnUnlisted foundModules) (warnMissing missingModules)
    return (foundModules, dotCabalPaths, warnings)
  where
    loop [] _ = return (S.empty, M.empty, [])
    loop names doneModules0 = do
        resolved <- resolveFiles dirs names
        let foundFiles = mapMaybe snd resolved
            foundModules = mapMaybe toResolvedModule resolved
            missingModules = mapMaybe toMissingModule resolved
        pairs <- mapM (getDependencies component) foundFiles
        let doneModules =
                S.union
                    doneModules0
                    (S.fromList (mapMaybe dotCabalModule names))
            moduleDeps = S.unions (map fst pairs)
            thDepFiles = concatMap snd pairs
            modulesRemaining = S.difference moduleDeps doneModules
        -- Ignore missing modules discovered as dependencies - they may
        -- have been deleted.
        (resolvedFiles, resolvedModules, _) <-
            loop (map DotCabalModule (S.toList modulesRemaining)) doneModules
        return
            ( S.union
                  (S.fromList
                       (foundFiles <> map DotCabalFilePath thDepFiles))
                  resolvedFiles
            , M.union
                  (M.fromList foundModules)
                  resolvedModules
            , missingModules)
    warnUnlisted foundModules = do
        let unlistedModules =
                foundModules `M.difference`
                M.fromList (mapMaybe (fmap (, ()) . dotCabalModule) names0)
        return $
            if M.null unlistedModules
                then []
                else [ UnlistedModulesWarning
                           component
                           (map fst (M.toList unlistedModules))]
    warnMissing _missingModules = do
        return []
        -- TODO: bring this back - see
        -- https://github.com/commercialhaskell/stack/issues/2649
        {-
        cabalfp <- asks ctxFile
        return $
            if null missingModules
               then []
               else [ MissingModulesWarning
                           cabalfp
                           component
                           missingModules]
        -}
    -- TODO: In usages of toResolvedModule / toMissingModule, some sort
    -- of map + partition would probably be better.
    toResolvedModule
        :: (DotCabalDescriptor, Maybe DotCabalPath)
        -> Maybe (ModuleName, Path Abs File)
    toResolvedModule (DotCabalModule mn, Just (DotCabalModulePath fp)) =
        Just (mn, fp)
    toResolvedModule _ =
        Nothing
    toMissingModule
        :: (DotCabalDescriptor, Maybe DotCabalPath)
        -> Maybe ModuleName
    toMissingModule (DotCabalModule mn, Nothing) =
        Just mn
    toMissingModule _ =
        Nothing

-- | Get the dependencies of a Haskell module file.
getDependencies
    :: NamedComponent -> DotCabalPath -> RIO Ctx (Set ModuleName, [Path Abs File])
getDependencies component dotCabalPath =
    case dotCabalPath of
        DotCabalModulePath resolvedFile -> readResolvedHi resolvedFile
        DotCabalMainPath resolvedFile -> readResolvedHi resolvedFile
        DotCabalFilePath{} -> return (S.empty, [])
        DotCabalCFilePath{} -> return (S.empty, [])
  where
    readResolvedHi resolvedFile = do
        dumpHIDir <- componentOutputDir component <$> asks ctxDistDir
        dir <- asks (parent . ctxFile)
        case stripProperPrefix dir resolvedFile of
            Nothing -> return (S.empty, [])
            Just fileRel -> do
                let dumpHIPath =
                        FilePath.replaceExtension
                            (toFilePath (dumpHIDir </> fileRel))
                            ".dump-hi"
                dumpHIExists <- liftIO $ D.doesFileExist dumpHIPath
                if dumpHIExists
                    then parseDumpHI dumpHIPath
                    else return (S.empty, [])

-- | Parse a .dump-hi file into a set of modules and files.
parseDumpHI
    :: FilePath -> RIO Ctx (Set ModuleName, [Path Abs File])
parseDumpHI dumpHIPath = do
    dir <- asks (parent . ctxFile)
    dumpHI <- liftIO $ filterDumpHi <$> fmap CL8.lines (CL8.readFile dumpHIPath)
    let startModuleDeps =
            dropWhile (not . ("module dependencies:" `CL8.isPrefixOf`)) dumpHI
        moduleDeps =
            S.fromList $
            mapMaybe (D.simpleParse . TL.unpack . TLE.decodeUtf8) $
            CL8.words $
            CL8.concat $
            CL8.dropWhile (/= ' ') (fromMaybe "" $ listToMaybe startModuleDeps) :
            takeWhile (" " `CL8.isPrefixOf`) (drop 1 startModuleDeps)
        thDeps =
            -- The dependent file path is surrounded by quotes but is not escaped.
            -- It can be an absolute or relative path.
                  TL.unpack .
                  -- Starting with GHC 8.4.3, there's a hash following
                  -- the path. See
                  -- https://github.com/yesodweb/yesod/issues/1551
                  TLE.decodeUtf8 .
                  CL8.takeWhile (/= '\"') <$>
            mapMaybe (CL8.stripPrefix "addDependentFile \"") dumpHI
    thDepsResolved <- liftM catMaybes $ forM thDeps $ \x -> do
        mresolved <- liftIO (forgivingAbsence (resolveFile dir x)) >>= rejectMissingFile
        when (isNothing mresolved) $
            prettyWarnL
                [ flow "addDependentFile path (Template Haskell) listed in"
                , style File $ fromString dumpHIPath
                , flow "does not exist:"
                , style File $ fromString x
                ]
        return mresolved
    return (moduleDeps, thDepsResolved)
  where
    -- | Filtering step fixing RAM usage upon a big dump-hi file. See
    --   https://github.com/commercialhaskell/stack/issues/4027 It is
    --   an optional step from a functionality stand-point.
    filterDumpHi dumpHI =
        let dl x xs = x ++ xs
            isLineInteresting (acc, moduleDepsStarted) l
                | moduleDepsStarted && " " `CL8.isPrefixOf` l =
                    (acc . dl [l], True)
                | "module dependencies:" `CL8.isPrefixOf` l =
                    (acc . dl [l], True)
                | "addDependentFile \"" `CL8.isPrefixOf` l =
                    (acc . dl [l], False)
                | otherwise = (acc, False)
         in fst (foldl' isLineInteresting (dl [], False) dumpHI) []


-- | Try to resolve the list of base names in the given directory by
-- looking for unique instances of base names applied with the given
-- extensions.
resolveFiles
    :: [Path Abs Dir] -- ^ Directories to look in.
    -> [DotCabalDescriptor] -- ^ Base names.
    -> RIO Ctx [(DotCabalDescriptor, Maybe DotCabalPath)]
resolveFiles dirs names =
    forM names (\name -> liftM (name, ) (findCandidate dirs name))

data CabalFileNameParseFail
  = CabalFileNameParseFail FilePath
  | CabalFileNameInvalidPackageName FilePath
  deriving (Typeable)

instance Exception CabalFileNameParseFail
instance Show CabalFileNameParseFail where
    show (CabalFileNameParseFail fp) = "Invalid file path for cabal file, must have a .cabal extension: " ++ fp
    show (CabalFileNameInvalidPackageName fp) = "cabal file names must use valid package names followed by a .cabal extension, the following is invalid: " ++ fp

-- | Parse a package name from a file path.
parsePackageNameFromFilePath :: MonadThrow m => Path a File -> m PackageName
parsePackageNameFromFilePath fp = do
    base <- clean $ toFilePath $ filename fp
    case parsePackageName base of
        Nothing -> throwM $ CabalFileNameInvalidPackageName $ toFilePath fp
        Just x -> return x
  where clean = liftM reverse . strip . reverse
        strip ('l':'a':'b':'a':'c':'.':xs) = return xs
        strip _ = throwM (CabalFileNameParseFail (toFilePath fp))

-- | Find a candidate for the given module-or-filename from the list
-- of directories and given extensions.
findCandidate
    :: [Path Abs Dir]
    -> DotCabalDescriptor
    -> RIO Ctx (Maybe DotCabalPath)
findCandidate dirs name = do
    pkg <- asks ctxFile >>= parsePackageNameFromFilePath
    candidates <- liftIO makeNameCandidates
    case candidates of
        [candidate] -> return (Just (cons candidate))
        [] -> do
            case name of
                DotCabalModule mn
                  | D.display mn /= paths_pkg pkg -> logPossibilities dirs mn
                _ -> return ()
            return Nothing
        (candidate:rest) -> do
            warnMultiple name candidate rest
            return (Just (cons candidate))
  where
    cons =
        case name of
            DotCabalModule{} -> DotCabalModulePath
            DotCabalMain{} -> DotCabalMainPath
            DotCabalFile{} -> DotCabalFilePath
            DotCabalCFile{} -> DotCabalCFilePath
    paths_pkg pkg = "Paths_" ++ packageNameString pkg
    makeNameCandidates =
        liftM (nubOrd . concat) (mapM makeDirCandidates dirs)
    makeDirCandidates :: Path Abs Dir
                      -> IO [Path Abs File]
    makeDirCandidates dir =
        case name of
            DotCabalMain fp -> resolveCandidate dir fp
            DotCabalFile fp -> resolveCandidate dir fp
            DotCabalCFile fp -> resolveCandidate dir fp
            DotCabalModule mn -> do
              let perExt ext =
                     resolveCandidate dir (Cabal.toFilePath mn ++ "." ++ T.unpack ext)
              withHaskellExts <- mapM perExt haskellFileExts
              withPPExts <- mapM perExt haskellPreprocessorExts
              pure $
                case (concat withHaskellExts, concat withPPExts) of
                  -- If we have exactly 1 Haskell extension and exactly
                  -- 1 preprocessor extension, assume the former file is
                  -- generated from the latter
                  --
                  -- See https://github.com/commercialhaskell/stack/issues/4076
                  ([_], [y]) -> [y]

                  -- Otherwise, return everything
                  (xs, ys) -> xs ++ ys
    resolveCandidate
        :: (MonadIO m, MonadThrow m)
        => Path Abs Dir -> FilePath.FilePath -> m [Path Abs File]
    resolveCandidate x y = do
        -- The standard canonicalizePath does not work for this case
        p <- parseCollapsedAbsFile (toFilePath x FilePath.</> y)
        exists <- doesFileExist p
        return $ if exists then [p] else []

-- | Warn the user that multiple candidates are available for an
-- entry, but that we picked one anyway and continued.
warnMultiple
    :: DotCabalDescriptor -> Path b t -> [Path b t] -> RIO Ctx ()
warnMultiple name candidate rest =
    -- TODO: figure out how to style 'name' and the dispOne stuff
    prettyWarnL
        [ flow "There were multiple candidates for the Cabal entry"
        , fromString . showName $ name
        , line <> bulletedList (map dispOne (candidate:rest))
        , line <> flow "picking:"
        , dispOne candidate
        ]
  where showName (DotCabalModule name') = D.display name'
        showName (DotCabalMain fp) = fp
        showName (DotCabalFile fp) = fp
        showName (DotCabalCFile fp) = fp
        dispOne = fromString . toFilePath
          -- TODO: figure out why dispOne can't be just `display`
          --       (remove the .hlint.yaml exception if it can be)

-- | Log that we couldn't find a candidate, but there are
-- possibilities for custom preprocessor extensions.
--
-- For example: .erb for a Ruby file might exist in one of the
-- directories.
logPossibilities
    :: HasRunner env
    => [Path Abs Dir] -> ModuleName -> RIO env ()
logPossibilities dirs mn = do
    possibilities <- liftM concat (makePossibilities mn)
    unless (null possibilities) $ prettyWarnL
        [ flow "Unable to find a known candidate for the Cabal entry"
        , (style PP.Module . fromString $ D.display mn) <> ","
        , flow "but did find:"
        , line <> bulletedList (map display possibilities)
        , flow "If you are using a custom preprocessor for this module"
        , flow "with its own file extension, consider adding the file(s)"
        , flow "to your .cabal under extra-source-files."
        ]
  where
    makePossibilities name =
        mapM
            (\dir ->
                  do (_,files) <- listDir dir
                     return
                         (map
                              filename
                              (filter
                                   (isPrefixOf (D.display name) .
                                    toFilePath . filename)
                                   files)))
            dirs

-- | Path for the package's build log.
buildLogPath :: (MonadReader env m, HasBuildConfig env, MonadThrow m)
             => Package -> Maybe String -> m (Path Abs File)
buildLogPath package' msuffix = do
  env <- ask
  let stack = getProjectWorkDir env
  fp <- parseRelFile $ concat $
    packageIdentifierString (packageIdentifier package') :
    maybe id (\suffix -> ("-" :) . (suffix :)) msuffix [".log"]
  return $ stack </> relDirLogs </> fp

-- Internal helper to define resolveFileOrWarn and resolveDirOrWarn
resolveOrWarn :: Text
              -> (Path Abs Dir -> String -> RIO Ctx (Maybe a))
              -> FilePath.FilePath
              -> RIO Ctx (Maybe a)
resolveOrWarn subject resolver path =
  do cwd <- liftIO getCurrentDir
     file <- asks ctxFile
     dir <- asks (parent . ctxFile)
     result <- resolver dir path
     when (isNothing result) $
       prettyWarnL
           [ fromString . T.unpack $ subject -- TODO: needs style?
           , flow "listed in"
           , maybe (display file) display (stripProperPrefix cwd file)
           , flow "file does not exist:"
           , style Dir . fromString $ path
           ]
     return result

-- | Resolve the file, if it can't be resolved, warn for the user
-- (purely to be helpful).
resolveFileOrWarn :: FilePath.FilePath
                  -> RIO Ctx (Maybe (Path Abs File))
resolveFileOrWarn = resolveOrWarn "File" f
  where f p x = liftIO (forgivingAbsence (resolveFile p x)) >>= rejectMissingFile

-- | Resolve the directory, if it can't be resolved, warn for the user
-- (purely to be helpful).
resolveDirOrWarn :: FilePath.FilePath
                 -> RIO Ctx (Maybe (Path Abs Dir))
resolveDirOrWarn = resolveOrWarn "Directory" f
  where f p x = liftIO (forgivingAbsence (resolveDir p x)) >>= rejectMissingDir

-- | Create a 'LocalPackageView' from a directory containing a package.
mkLocalPackageView
  :: forall env. HasConfig env
  => PrintWarnings
  -> ResolvedPath Dir
  -> RIO env LocalPackageView
mkLocalPackageView printWarnings dir = do
  (gpd, name, cabalfp) <- loadCabalFilePath (resolvedAbsolute dir)
  return LocalPackageView
    { lpvCabalFP = cabalfp
    , lpvGPD' = gpd printWarnings
    , lpvResolvedDir = dir
    , lpvName = name
    }
