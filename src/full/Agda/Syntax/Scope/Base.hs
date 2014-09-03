{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}


{-| This module defines the notion of a scope and operations on scopes.
-}
module Agda.Syntax.Scope.Base where

import Control.Arrow ((***), first, second)
import Control.Applicative

import Data.Function
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Typeable (Typeable)

import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Fixity
import Agda.Syntax.Abstract.Name as A
import Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Concrete
  (ImportDirective(..), UsingOrHiding(..), ImportedName(..), Renaming(..))

import qualified Agda.Utils.AssocList as AssocList
import Agda.Utils.Functor
import Agda.Utils.List
import qualified Agda.Utils.Map as Map

#include "../../undefined.h"
import Agda.Utils.Impossible

-- * Scope representation

-- | A scope is a named collection of names partitioned into public and private
--   names.
data Scope = Scope
      { scopeName           :: A.ModuleName
      , scopeParents        :: [A.ModuleName]
      , scopeNameSpaces     :: ScopeNameSpaces
      , scopeImports        :: Map C.QName A.ModuleName
      , scopeDatatypeModule :: Bool
      }
  deriving (Typeable)

data NameSpaceId = PrivateNS | PublicNS | ImportedNS | OnlyQualifiedNS
  deriving (Typeable, Eq, Bounded, Enum)

type ScopeNameSpaces = [(NameSpaceId, NameSpace)]

localNameSpace :: Access -> NameSpaceId
localNameSpace PublicAccess  = PublicNS
localNameSpace PrivateAccess = PrivateNS
localNameSpace OnlyQualified = OnlyQualifiedNS

nameSpaceAccess :: NameSpaceId -> Access
nameSpaceAccess PrivateNS = PrivateAccess
nameSpaceAccess _         = PublicAccess

-- | Get a 'NameSpace' from 'Scope'.
scopeNameSpace :: NameSpaceId -> Scope -> NameSpace
scopeNameSpace ns = fromMaybe __IMPOSSIBLE__ . lookup ns . scopeNameSpaces

-- | A lens for 'scopeNameSpaces'
updateScopeNameSpaces :: (ScopeNameSpaces -> ScopeNameSpaces) -> Scope -> Scope
updateScopeNameSpaces f s = s { scopeNameSpaces = f (scopeNameSpaces s) }

-- | ``Monadic'' lens (Functor sufficient).
updateScopeNameSpacesM ::
  (Functor m) => (ScopeNameSpaces -> m ScopeNameSpaces) -> Scope -> m Scope
updateScopeNameSpacesM f s = for (f $ scopeNameSpaces s) $ \ x ->
  s { scopeNameSpaces = x }

-- | The complete information about the scope at a particular program point
--   includes the scope stack, the local variables, and the context precedence.
data ScopeInfo = ScopeInfo
      { scopeCurrent    :: A.ModuleName
      , scopeModules    :: Map A.ModuleName Scope
      , scopeLocals	:: LocalVars
      , scopePrecedence :: Precedence
      }
  deriving (Typeable)

-- | Local variables.
type LocalVars = [(C.Name, A.Name)]

-- | Lens for 'scopeLocals'.
updateScopeLocals :: (LocalVars -> LocalVars) -> ScopeInfo -> ScopeInfo
updateScopeLocals f sc = sc { scopeLocals = f (scopeLocals sc) }

setScopeLocals :: LocalVars -> ScopeInfo -> ScopeInfo
setScopeLocals vars = updateScopeLocals (const vars)

------------------------------------------------------------------------
-- * Name spaces
--
-- Map concrete names to lists of abstract names.
------------------------------------------------------------------------

-- | A @NameSpace@ contains the mappings from concrete names that the user can
--   write to the abstract fully qualified names that the type checker wants to
--   read.
data NameSpace = NameSpace
      { nsNames	  :: NamesInScope
        -- ^ Maps concrete names to a list of abstract names.
      , nsModules :: ModulesInScope
        -- ^ Maps concrete module names to a list of abstract module names.
      }
  deriving (Typeable)

type ThingsInScope a = Map C.Name [a]
type NamesInScope    = ThingsInScope AbstractName
type ModulesInScope  = ThingsInScope AbstractModule

-- | Set of types consisting of exactly 'AbstractName' and 'AbstractModule'.
--
--   A GADT just for some dependent-types trickery.
data InScopeTag a where
  NameTag   :: InScopeTag AbstractName
  ModuleTag :: InScopeTag AbstractModule

-- | Type class for some dependent-types trickery.
class Eq a => InScope a where
  inScopeTag :: InScopeTag a

instance InScope AbstractName where
  inScopeTag = NameTag

instance InScope AbstractModule where
  inScopeTag = ModuleTag

-- | @inNameSpace@ selects either the name map or the module name map from
--   a 'NameSpace'.  What is selected is determined by result type
--   (using the dependent-type trickery).
inNameSpace :: forall a. InScope a => NameSpace -> ThingsInScope a
inNameSpace = case inScopeTag :: InScopeTag a of
  NameTag   -> nsNames
  ModuleTag -> nsModules

------------------------------------------------------------------------
-- * Decorated names
--
-- - What kind of name? (defined, constructor...)
-- - Where does the name come from? (to explain to user)
------------------------------------------------------------------------

-- | For the sake of parsing left-hand sides, we distinguish
--   constructor and record field names from defined names.
data KindOfName
  = ConName        -- ^ Constructor name.
  | FldName        -- ^ Record field name.
  | DefName        -- ^ Ordinary defined name.
  | PatternSynName -- ^ Name of a pattern synonym.
  | QuotableName   -- ^ A name that can only quoted.
  deriving (Eq, Show, Typeable, Enum, Bounded)

-- | A list containing all name kinds.
allKindsOfNames :: [KindOfName]
allKindsOfNames = [minBound..maxBound]

-- | Where does a name come from?
--
--   This information is solely for reporting to the user,
--   see 'Agda.Interaction.InteractionTop.whyInScope'.
data WhyInScope
  = Defined
    -- ^ Defined in this module.
  | Opened C.QName WhyInScope
    -- ^ Imported from another module.
  | Applied C.QName WhyInScope
    -- ^ Imported by a module application.
  deriving (Typeable)

-- | A decoration of 'Agda.Syntax.Abstract.Name.QName'.
data AbstractName = AbsName
  { anameName    :: A.QName
    -- ^ The resolved qualified name.
  , anameKind    :: KindOfName
    -- ^ The kind (definition, constructor, record field etc.).
  , anameLineage :: WhyInScope
    -- ^ Explanation where this name came from.
  }
  deriving (Typeable)

-- | A decoration of abstract syntax module names.
data AbstractModule = AbsModule
  { amodName    :: A.ModuleName
    -- ^ The resolved module name.
  , amodLineage :: WhyInScope
    -- ^ Explanation where this name came from.
  }
  deriving (Typeable)

instance Eq AbstractName where
  (==) = (==) `on` anameName

instance Ord AbstractName where
  compare = compare `on` anameName

instance Eq AbstractModule where
  (==) = (==) `on` amodName

instance Ord AbstractModule where
  compare = compare `on` amodName

-- * Operations on name and module maps.

mergeNames :: Eq a => ThingsInScope a -> ThingsInScope a -> ThingsInScope a
mergeNames = Map.unionWith union

------------------------------------------------------------------------
-- * Operations on name spaces
------------------------------------------------------------------------

-- | The empty name space.
emptyNameSpace :: NameSpace
emptyNameSpace = NameSpace Map.empty Map.empty


-- | Map functions over the names and modules in a name space.
mapNameSpace :: (NamesInScope   -> NamesInScope  ) ->
		(ModulesInScope -> ModulesInScope) ->
		NameSpace -> NameSpace
mapNameSpace fd fm ns =
  ns { nsNames	 = fd $ nsNames ns
     , nsModules = fm $ nsModules  ns
     }

-- | Zip together two name spaces.
zipNameSpace :: (NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
		(ModulesInScope -> ModulesInScope -> ModulesInScope) ->
		NameSpace -> NameSpace -> NameSpace
zipNameSpace fd fm ns1 ns2 =
  ns1 { nsNames	  = nsNames   ns1 `fd` nsNames   ns2
      , nsModules = nsModules ns1 `fm` nsModules ns2
      }

-- | Map monadic function over a namespace.
mapNameSpaceM :: Applicative m =>
  (NamesInScope   -> m NamesInScope  ) ->
  (ModulesInScope -> m ModulesInScope) ->
  NameSpace -> m NameSpace
mapNameSpaceM fd fm ns = update ns <$> fd (nsNames ns) <*> fm (nsModules ns)
  where
    update ns ds ms = ns { nsNames = ds, nsModules = ms }

------------------------------------------------------------------------
-- * General operations on scopes
------------------------------------------------------------------------

-- | The empty scope.
emptyScope :: Scope
emptyScope = Scope
  { scopeName           = noModuleName
  , scopeParents        = []
  , scopeNameSpaces     = [ (nsid, emptyNameSpace) | nsid <- [minBound..maxBound] ]
  , scopeImports        = Map.empty
  , scopeDatatypeModule = False
  }

-- | The empty scope info.
emptyScopeInfo :: ScopeInfo
emptyScopeInfo = ScopeInfo
  { scopeCurrent    = noModuleName
  , scopeModules    = Map.singleton noModuleName emptyScope
  , scopeLocals	    = []
  , scopePrecedence = TopCtx
  }

-- | Map functions over the names and modules in a scope.
mapScope :: (NameSpaceId -> NamesInScope   -> NamesInScope  ) ->
	    (NameSpaceId -> ModulesInScope -> ModulesInScope) ->
	    Scope -> Scope
mapScope fd fm = updateScopeNameSpaces $ AssocList.mapWithKey mapNS
  where
    mapNS acc = mapNameSpace (fd acc) (fm acc)

-- | Same as 'mapScope' but applies the same function to all name spaces.
mapScope_ :: (NamesInScope   -> NamesInScope  ) ->
	     (ModulesInScope -> ModulesInScope) ->
	     Scope -> Scope
mapScope_ fd fm = mapScope (const fd) (const fm)

-- | Map monadic functions over the names and modules in a scope.
mapScopeM :: (Functor m, Applicative m) =>
  (NameSpaceId -> NamesInScope   -> m NamesInScope  ) ->
  (NameSpaceId -> ModulesInScope -> m ModulesInScope) ->
  Scope -> m Scope
mapScopeM fd fm = updateScopeNameSpacesM $ AssocList.mapWithKeyM mapNS
  where
    mapNS acc = mapNameSpaceM (fd acc) (fm acc)

-- | Same as 'mapScopeM' but applies the same function to both the public and
--   private name spaces.
mapScopeM_ :: (Functor m, Applicative m) =>
  (NamesInScope   -> m NamesInScope  ) ->
  (ModulesInScope -> m ModulesInScope) ->
  Scope -> m Scope
mapScopeM_ fd fm = mapScopeM (const fd) (const fm)

-- | Zip together two scopes. The resulting scope has the same name as the
--   first scope.
zipScope :: (NameSpaceId -> NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
	    (NameSpaceId -> ModulesInScope -> ModulesInScope -> ModulesInScope) ->
	    Scope -> Scope -> Scope
zipScope fd fm s1 s2 =
  s1 { scopeNameSpaces = [ (nsid, zipNS nsid ns1 ns2)
                         | ((nsid, ns1), (nsid', ns2)) <- zipWith' (,) (scopeNameSpaces s1) (scopeNameSpaces s2)
                         , assert (nsid == nsid')
                         ]
     , scopeImports  = Map.union (scopeImports s1) (scopeImports s2)
     }
  where
    assert True  = True
    assert False = __IMPOSSIBLE__
    zipNS acc = zipNameSpace (fd acc) (fm acc)

-- | Same as 'zipScope' but applies the same function to both the public and
--   private name spaces.
zipScope_ :: (NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
	     (ModulesInScope -> ModulesInScope -> ModulesInScope) ->
	     Scope -> Scope -> Scope
zipScope_ fd fm = zipScope (const fd) (const fm)

-- | Filter a scope keeping only concrete names matching the predicates.
--   The first predicate is applied to the names and the second to the modules.
filterScope :: (C.Name -> Bool) -> (C.Name -> Bool) -> Scope -> Scope
filterScope pd pm = mapScope_ (Map.filterKeys pd) (Map.filterKeys pm)

-- | Return all names in a scope.
allNamesInScope :: InScope a => Scope -> ThingsInScope a
allNamesInScope = namesInScope [minBound..maxBound]

allNamesInScope' :: InScope a => Scope -> ThingsInScope (a, Access)
allNamesInScope' s =
  foldr1 mergeNames [ map (, nameSpaceAccess ns) <$> namesInScope [ns] s
                    | ns <- [minBound..maxBound] ]

-- | Returns the scope's non-private names.
exportedNamesInScope :: InScope a => Scope -> ThingsInScope a
exportedNamesInScope = namesInScope [PublicNS, ImportedNS, OnlyQualifiedNS]

namesInScope :: InScope a => [NameSpaceId] -> Scope -> ThingsInScope a
namesInScope ids s =
  foldr1 mergeNames [ inNameSpace (scopeNameSpace nsid s) | nsid <- ids ]

allThingsInScope :: Scope -> NameSpace
allThingsInScope = thingsInScope [minBound..maxBound]

thingsInScope :: [NameSpaceId] -> Scope -> NameSpace
thingsInScope fs s =
  NameSpace { nsNames   = namesInScope fs s
            , nsModules = namesInScope fs s
            }

-- | Merge two scopes. The result has the name of the first scope.
mergeScope :: Scope -> Scope -> Scope
mergeScope = zipScope_ mergeNames mergeNames

-- | Merge a non-empty list of scopes. The result has the name of the first
--   scope in the list.
mergeScopes :: [Scope] -> Scope
mergeScopes [] = __IMPOSSIBLE__
mergeScopes ss = foldr1 mergeScope ss

-- * Specific operations on scopes

-- | Move all names in a scope to the given name space (except never move from
--   Imported to Public).
setScopeAccess :: NameSpaceId -> Scope -> Scope
setScopeAccess a s = (`updateScopeNameSpaces` s) $ AssocList.mapWithKey $ const . ns
  where
    zero  = emptyNameSpace
    one   = allThingsInScope s
    imp   = thingsInScope [ImportedNS] s
    noimp = thingsInScope [PublicNS, PrivateNS, OnlyQualifiedNS] s

    ns b = case (a, b) of
      (PublicNS, PublicNS)   -> noimp
      (PublicNS, ImportedNS) -> imp
      _ | a == b             -> one
        | otherwise          -> zero

-- | Update a particular name space.
setNameSpace :: NameSpaceId -> NameSpace -> Scope -> Scope
setNameSpace nsid ns = updateScopeNameSpaces $ AssocList.update nsid ns

-- | Add names to a scope.
addNamesToScope :: NameSpaceId -> C.Name -> [AbstractName] -> Scope -> Scope
addNamesToScope acc x ys s = mergeScope s s1
  where
    s1 = setScopeAccess acc $ setNameSpace PublicNS ns emptyScope
    ns = emptyNameSpace { nsNames = Map.singleton x ys }

-- | Add a name to a scope.
addNameToScope :: NameSpaceId -> C.Name -> AbstractName -> Scope -> Scope
addNameToScope acc x y s = addNamesToScope acc x [y] s

-- | Remove a name from a scope.
removeNameFromScope :: NameSpaceId -> C.Name -> Scope -> Scope
removeNameFromScope ns x s = mapScope remove (const id) s
  where
    remove ns' | ns' /= ns = id
               | otherwise = Map.delete x

-- | Add a module to a scope.
addModuleToScope :: NameSpaceId -> C.Name -> AbstractModule -> Scope -> Scope
addModuleToScope acc x m s = mergeScope s s1
  where
    s1 = setScopeAccess acc $ setNameSpace PublicNS ns emptyScope
    ns = emptyNameSpace { nsModules = Map.singleton x [m] }

-- | Apply an 'ImportDirective' to a scope.
applyImportDirective :: ImportDirective -> Scope -> Scope
applyImportDirective dir s = mergeScope usedOrHidden renamed
  where
    usedOrHidden = useOrHide (hideLHS (renaming dir) $ usingOrHiding dir) s
    renamed	 = rename (renaming dir) $ useOrHide useRenamedThings s

    useRenamedThings = Using $ map renFrom $ renaming dir

    hideLHS :: [Renaming] -> UsingOrHiding -> UsingOrHiding
    hideLHS _	i@(Using _) = i
    hideLHS ren (Hiding xs) = Hiding $ xs ++ map renFrom ren

    useOrHide :: UsingOrHiding -> Scope -> Scope
    useOrHide (Hiding xs) s = filterNames notElem notElem xs s
    useOrHide (Using  xs) s = filterNames elem	  elem	  xs s

    filterNames :: (C.Name -> [C.Name] -> Bool) -> (C.Name -> [C.Name] -> Bool) ->
		   [ImportedName] -> Scope -> Scope
    filterNames pd pm xs = filterScope' (flip pd ds) (flip pm ms)
      where
	ds = [ x | ImportedName   x <- xs ]
	ms = [ m | ImportedModule m <- xs ]

    filterScope' pd pm = filterScope pd pm

    -- Renaming
    rename :: [Renaming] -> Scope -> Scope
    rename rho = mapScope_ (Map.mapKeys $ ren drho)
			   (Map.mapKeys $ ren mrho)
      where
	mrho = [ (x, y) | Renaming { renFrom = ImportedModule x, renTo = y } <- rho ]
	drho = [ (x, y) | Renaming { renFrom = ImportedName   x, renTo = y } <- rho ]

	ren r x = maybe x id $ lookup x r

-- | Rename the abstract names in a scope.
renameCanonicalNames :: Map A.QName A.QName -> Map A.ModuleName A.ModuleName ->
			Scope -> Scope
renameCanonicalNames renD renM = mapScope_ renameD renameM
  where
    renameD = Map.map (map $ onName  rD)
    renameM = Map.map (map $ onMName rM)

    onName  f x = x { anameName = f $ anameName x }
    onMName f x = x { amodName  = f $ amodName  x }

    rD x = maybe x id $ Map.lookup x renD
    rM x = maybe x id $ Map.lookup x renM

-- | Restrict the private name space of a scope
restrictPrivate :: Scope -> Scope
restrictPrivate s = setNameSpace PrivateNS emptyNameSpace $ s { scopeImports = Map.empty }

-- | Remove names that can only be used qualified (when opening a scope)
removeOnlyQualified :: Scope -> Scope
removeOnlyQualified s = setNameSpace OnlyQualifiedNS emptyNameSpace s

-- | Add an explanation to why things are in scope.
inScopeBecause :: (WhyInScope -> WhyInScope) -> Scope -> Scope
inScopeBecause f = mapScope_ mapName mapMod
  where
    mapName = fmap . map $ \a -> a { anameLineage = f $ anameLineage a }
    mapMod  = fmap . map $ \a -> a { amodLineage  = f $ amodLineage a  }

-- | Get the public parts of the public modules of a scope
publicModules :: ScopeInfo -> Map A.ModuleName Scope
publicModules scope = Map.filterWithKey (\m _ -> reachable m) allMods
  where
    allMods   = Map.map restrictPrivate $ scopeModules scope
    root      = scopeCurrent scope
    modules s = map amodName $ concat $ Map.elems $ allNamesInScope s

    chase m = m : case Map.lookup m allMods of
      Just s  -> concatMap chase $ modules s
      Nothing -> __IMPOSSIBLE__

    reachable = (`elem` chase root)

everythingInScope :: ScopeInfo -> NameSpace
everythingInScope scope =
    allThingsInScope
    $ mergeScopes
    [ s | (m, s) <- Map.toList (scopeModules scope), m `elem` current ]
  where
    this    = scopeCurrent scope
    parents = case Map.lookup this (scopeModules scope) of
      Just s  -> scopeParents s
      Nothing -> __IMPOSSIBLE__
    current = this : parents

-- | Compute a flattened scope. Only include unqualified names or names
-- qualified by modules in the first argument.
flattenScope :: [[C.Name]] -> ScopeInfo -> Map C.QName [AbstractName]
flattenScope ms scope =
  -- Map.filterKeys (\q -> elem (init $ C.qnameParts q) ([]:ms)) $
  Map.unionWith (++)
    (build ms allNamesInScope root)
    imported
  where
    current = moduleScope $ scopeCurrent scope
    root    = mergeScopes $ current : map moduleScope (scopeParents current)

    imported = Map.unionsWith (++)
               [ qual c (build ms' exportedNamesInScope $ moduleScope a)
               | (c, a) <- Map.toList $ scopeImports root
               , let m   = C.qnameParts c
                     ms' = map (drop (length m)) $ filter (m `isPrefixOf`) ms
               , not $ null ms' ]
    qual c = Map.mapKeys (q c)
      where
        q (C.QName x)  = C.Qual x
        q (C.Qual m x) = C.Qual m . q x

    build :: [[C.Name]] -> (forall a. InScope a => Scope -> ThingsInScope a) -> Scope -> Map C.QName [AbstractName]
    build ms getNames s =
      Map.unionWith (++)
        (Map.mapKeys (\x -> C.QName x) (getNames s))
        $ Map.unionsWith (++) $
          [ Map.mapKeys (\y -> C.Qual x y) $ build ms' exportedNamesInScope $ moduleScope m
          | (x, mods) <- Map.toList (getNames s)
          , let ms' = [ ms' | m':ms' <- ms, m' == x ]
          , not $ null ms'
          , AbsModule m _ <- mods ]

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scopeModules scope

-- | Look up a name in the scope
scopeLookup :: InScope a => C.QName -> ScopeInfo -> [a]
scopeLookup q scope = map fst $ scopeLookup' q scope

scopeLookup' :: forall a. InScope a => C.QName -> ScopeInfo -> [(a, Access)]
scopeLookup' q scope = nubBy ((==) `on` fst) $ findName q root ++ imports
  where

    current :: Scope
    current = moduleScope $ scopeCurrent scope

    root    :: Scope
    root    = mergeScopes $ current : map moduleScope (scopeParents current)

    -- return all possible splittings, e.g.
    -- splitName X.Y.Z = [(X, Y.Z), (X.Y, Z)]
    splitName :: C.QName -> [(C.QName, C.QName)]
    splitName (C.QName x) = []
    splitName (C.Qual x q) = (C.QName x, q) : do
      (m, r) <- splitName q
      return (C.Qual x m, r)

    imported :: C.QName -> [(A.ModuleName, Access)]
    imported q = maybe [] ((:[]) . (, PublicAccess)) $ Map.lookup q $ scopeImports root

    topImports :: [(a, Access)]
    topImports = case (inScopeTag :: InScopeTag a) of
      NameTag   -> []
      ModuleTag -> map (first (`AbsModule` Defined)) (imported q)

    imports :: [(a, Access)]
    imports = topImports ++ do
      (m, x) <- splitName q
      m <- fst <$> imported m
      findName x (restrictPrivate $ moduleScope m)

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scopeModules scope

    lookupName :: forall a. InScope a => C.Name -> Scope -> [(a, Access)]
    lookupName x s = maybe [] id $ Map.lookup x (allNamesInScope' s)

    findName :: forall a. InScope a => C.QName -> Scope -> [(a, Access)]
    findName (C.QName x)  s = lookupName x s
    findName (C.Qual x q) s = do
        -- Andreas, 2013-05-01:  Issue 836 complains about the feature
        -- that constructors can also be qualified by their datatype
        -- and projections by their record type.  This feature is off
        -- if we just consider the modules:
        -- m <- mods
        -- The feature is on if we consider also the data and record types:
        m <- nub $ mods ++ defs -- record types will appear both as a mod and a def
        Just s' <- return $ Map.lookup m (scopeModules scope)
        findName q (restrictPrivate s')
      where
        mods, defs :: [ModuleName]
        mods = amodName . fst <$> lookupName x s
        -- Andreas, 2013-05-01: Issue 836 debates this feature:
        -- Qualified constructors are qualified by their datatype rather than a module
        defs = mnameFromList . qnameToList . anameName . fst <$> lookupName x s

-- * Inverse look-up

data AllowAmbiguousConstructors = AllowAmbiguousConstructors | NoAmbiguousConstructors
  deriving (Eq)

-- | Find the shortest concrete name that maps (uniquely) to a given abstract
--   name.
inverseScopeLookup :: Either A.ModuleName A.QName -> ScopeInfo -> Maybe C.QName
inverseScopeLookup = inverseScopeLookup' AllowAmbiguousConstructors

inverseScopeLookup' :: AllowAmbiguousConstructors -> Either A.ModuleName A.QName -> ScopeInfo -> Maybe C.QName
inverseScopeLookup' ambCon name scope = case name of
  Left  m -> best $ filter unambiguousModule $ findModule m
  Right q -> best $ filter unambiguousName   $ findName nameMap q
  where
    this = scopeCurrent scope
    current = this : scopeParents (moduleScope this)
    scopes  = [ (m, restrict m s) | (m, s) <- Map.toList (scopeModules scope) ]

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scopeModules scope

    restrict m s | m `elem` current = s
                 | otherwise = restrictPrivate s

    len :: C.QName -> Int
    len (C.QName _)  = 1
    len (C.Qual _ x) = 1 + len x

    best xs = case sortBy (compare `on` len) xs of
      []    -> Nothing
      x : _ -> Just x

    unique :: forall a . [a] -> Bool
    unique []      = __IMPOSSIBLE__
    unique [_]     = True
    unique (_:_:_) = False

    unambiguousModule q = unique (scopeLookup q scope :: [AbstractModule])
    unambiguousName   q = unique xs || AllowAmbiguousConstructors == ambCon && all ((ConName ==) . anameKind) xs
      where xs = scopeLookup q scope

    findName :: Ord a => Map a [(A.ModuleName, C.Name)] -> a -> [C.QName]
    findName table q = do
      (m, x) <- maybe [] id $ Map.lookup q table
      if m `elem` current
        then return (C.QName x)
        else do
          y <- findModule m
          return $ C.qualify y x

    findModule :: A.ModuleName -> [C.QName]
    findModule q = findName moduleMap q ++
                   maybe [] id (Map.lookup q importMap)

    importMap = Map.unionsWith (++) $ do
      (m, s) <- scopes
      (x, y) <- Map.toList $ scopeImports s
      return $ Map.singleton y [x]

    moduleMap = Map.unionsWith (++) $ do
      (m, s)  <- scopes
      (x, ms) <- Map.toList (allNamesInScope s)
      q       <- amodName <$> ms
      return $ Map.singleton q [(m, x)]

    nameMap = Map.unionsWith (++) $ do
      (m, s)  <- scopes
      (x, ms) <- Map.toList (allNamesInScope s)
      q       <- anameName <$> ms
      return $ Map.singleton q [(m, x)]

-- | Takes the first component of 'inverseScopeLookup'.
inverseScopeLookupName :: A.QName -> ScopeInfo -> Maybe C.QName
inverseScopeLookupName x = inverseScopeLookup (Right x)

inverseScopeLookupName' :: AllowAmbiguousConstructors -> A.QName -> ScopeInfo -> Maybe C.QName
inverseScopeLookupName' ambCon x = inverseScopeLookup' ambCon (Right x)

-- | Takes the second component of 'inverseScopeLookup'.
inverseScopeLookupModule :: A.ModuleName -> ScopeInfo -> Maybe C.QName
inverseScopeLookupModule x = inverseScopeLookup (Left x)

------------------------------------------------------------------------
-- * (Debug) printing
------------------------------------------------------------------------

instance Show AbstractName where
  show = show . anameName

instance Show AbstractModule where
  show = show . amodName

instance Show NameSpaceId where
  show nsid = case nsid of
    PublicNS        -> "public"
    PrivateNS       -> "private"
    ImportedNS      -> "imported"
    OnlyQualifiedNS -> "only-qualified"

instance Show NameSpace where
  show (NameSpace names mods) =
    unlines $
      blockOfLines "names"   (map pr $ Map.toList names) ++
      blockOfLines "modules" (map pr $ Map.toList mods)
    where
      pr :: (Show a, Show b) => (a,b) -> String
      pr (x, y) = show x ++ " --> " ++ show y

instance Show Scope where
  show (scope @ Scope { scopeName = name, scopeParents = parents, scopeImports = imps }) =
    unlines $
      [ "* scope " ++ show name ] ++ ind (
        concat [ blockOfLines (show nsid) (lines $ show $ scopeNameSpace nsid scope)
               | nsid <- [minBound..maxBound] ]
      ++ blockOfLines "imports"  (case Map.keys imps of
                                    [] -> []
                                    ks -> [ show ks ]
                                 )
      )
    where ind = map ("  " ++)

-- | Add first string only if list is non-empty.
blockOfLines :: String -> [String] -> [String]
blockOfLines _  [] = []
blockOfLines hd ss = hd : map ("  " ++) ss

instance Show ScopeInfo where
  show (ScopeInfo this mods locals ctx) =
    unlines $
      [ "ScopeInfo"
      , "  current = " ++ show this
      ] ++
      (if null locals then [] else [ "  locals  = " ++ show locals ]) ++
      [ "  context = " ++ show ctx
      , "  modules"
      ] ++ map ("    "++) (relines . map show $ Map.elems mods)
    where
      relines = filter (not . null) . lines . unlines

------------------------------------------------------------------------
-- * Boring instances
------------------------------------------------------------------------

instance KillRange ScopeInfo where
  killRange m = m

instance HasRange AbstractName where
  getRange = getRange . anameName

instance SetRange AbstractName where
  setRange r x = x { anameName = setRange r $ anameName x }
