{- Data/Singletons/Single.hs

(c) Richard Eisenberg 2013
eir@cis.upenn.edu

This file contains functions to refine constructs to work with singleton
types. It is an internal module to the singletons package.
-}
{-# LANGUAGE TemplateHaskell, TupleSections, ParallelListComp, CPP #-}

module Data.Singletons.Single where

import Prelude hiding ( exp )
import Language.Haskell.TH hiding ( cxt )
import Language.Haskell.TH.Syntax (Quasi(..))
import Data.Singletons.Deriving.Ord
import Data.Singletons.Deriving.Bounded
import Data.Singletons.Util
import Data.Singletons.Promote
import Data.Singletons.Promote.Monad ( promoteM )
import Data.Singletons.Promote.Type
import Data.Singletons.Names
import Data.Singletons.Single.Monad
import Data.Singletons.Single.Type
import Data.Singletons.Single.Data
import Data.Singletons.Single.Eq
import Data.Singletons.Syntax
import Data.Singletons.Partition
import Language.Haskell.TH.Desugar
import qualified Data.Map.Strict as Map
import Data.Map.Strict ( Map )
import Data.Maybe
import Control.Monad
import Data.List

{-
How singletons works
~~~~~~~~~~~~~~~~~~~~

Singling, on the surface, doesn't seem all that complicated. Promote the type,
and singletonize all the terms. That's essentially what was done singletons < 1.0.
But, now we want to deal with higher-order singletons. So, things are a little
more complicated.

The way to understand all of this is that *every* variable maps to something
of type (Sing t), for an appropriately-kinded t. This includes functions, which
use the "SLambda" instance of Sing. To apply singleton functions, we use the
applySing function.

That, in and of itself, wouldn't be too hard, but it's really annoying from
the user standpoint. After dutifully singling `map`, a user doesn't want to
have to use two `applySing`s to actually use it. So, any let-bound identifier
is eta-expanded so that the singled type has the same number of arrows as
the original type. (If there is no original type signature, then it has as
many arrows as the original had patterns.) Then, we store a use of one of the
singFunX functions in the SgM environment so that every use of a let-bound
identifier has a proper type (Sing t).

It would be consistent to avoid this eta-expansion for local lets (as opposed
to top-level lets), but that seemed like more bother than it was worth. It
may also be possible to be cleverer about nested eta-expansions and contractions,
but that also seemed not to be worth it. Though I haven't tested it, my hope
is that the eta-expansions and contractions have no runtime effect, especially
because SLambda is a *newtype* instance, not a *data* instance.

Note that to maintain the desired invariant, we must also be careful to eta-
contract constructors. This is the point of buildDataLets.
-}

-- | Generate singleton definitions from a type that is already defined.
-- For example, the singletons package itself uses
--
-- > $(genSingletons [''Bool, ''Maybe, ''Either, ''[]])
--
-- to generate singletons for Prelude types.
genSingletons :: DsMonad q => [Name] -> q [Dec]
genSingletons names = do
  checkForRep names
  ddecs <- concatMapM (singInfo <=< dsInfo <=< reifyWithWarning) names
  return $ decsToTH ddecs

-- | Make promoted and singleton versions of all declarations given, retaining
-- the original declarations.
-- See <http://www.cis.upenn.edu/~eir/packages/singletons/README.html> for
-- further explanation.
singletons :: DsMonad q => q [Dec] -> q [Dec]
singletons qdecs = do
  decs <- qdecs
  singDecs <- wrapDesugar singTopLevelDecs decs
  return (decs ++ singDecs)

-- | Make promoted and singleton versions of all declarations given, discarding
-- the original declarations.
singletonsOnly :: DsMonad q => q [Dec] -> q [Dec]
singletonsOnly = (>>= wrapDesugar singTopLevelDecs)

-- | Create instances of 'SEq' and type-level '(:==)' for each type in the list
singEqInstances :: DsMonad q => [Name] -> q [Dec]
singEqInstances = concatMapM singEqInstance

-- | Create instance of 'SEq' and type-level '(:==)' for the given type
singEqInstance :: DsMonad q => Name -> q [Dec]
singEqInstance name = do
  promotion <- promoteEqInstance name
  dec <- singEqualityInstance sEqClassDesc name
  return $ dec ++ promotion

-- | Create instances of 'SEq' (only -- no instance for '(:==)', which 'SEq' generally
-- relies on) for each type in the list
singEqInstancesOnly :: DsMonad q => [Name] -> q [Dec]
singEqInstancesOnly = concatMapM singEqInstanceOnly

-- | Create instances of 'SEq' (only -- no instance for '(:==)', which 'SEq' generally
-- relies on) for the given type
singEqInstanceOnly :: DsMonad q => Name -> q [Dec]
singEqInstanceOnly name = singEqualityInstance sEqClassDesc name

-- | Create instances of 'SDecide' for each type in the list.
singDecideInstances :: DsMonad q => [Name] -> q [Dec]
singDecideInstances = concatMapM singDecideInstance

-- | Create instance of 'SDecide' for the given type.
singDecideInstance :: DsMonad q => Name -> q [Dec]
singDecideInstance name = singEqualityInstance sDecideClassDesc name

-- generalized function for creating equality instances
singEqualityInstance :: DsMonad q => EqualityClassDesc q -> Name -> q [Dec]
singEqualityInstance desc@(_, className, _) name = do
  (tvbs, cons) <- getDataD ("I cannot make an instance of " ++
                            show className ++ " for it.") name
  dtvbs <- mapM dsTvb tvbs
  dcons <- mapM dsCon cons
  let tyvars = map (DVarK . extractTvbName) dtvbs
      kind = DConK name tyvars
  aName <- qNewName "a"
  let aVar = DVarT aName
  (scons, _) <- singM [] $ mapM (singCtor aVar) dcons
  eqInstance <- mkEqualityInstance kind scons desc
  return $ decToTH eqInstance

-- | Create instances of 'SOrd' for the given types
singOrdInstances :: DsMonad q => [Name] -> q [Dec]
singOrdInstances = concatMapM singOrdInstance

-- | Create instance of 'SOrd' for the given type
singOrdInstance :: DsMonad q => Name -> q [Dec]
singOrdInstance = singInstance mkOrdInstance "Ord"

-- | Create instances of 'SBounded' for the given types
singBoundedInstances :: DsMonad q => [Name] -> q [Dec]
singBoundedInstances = concatMapM singBoundedInstance

-- | Create instance of 'SBounded' for the given type
singBoundedInstance :: DsMonad q => Name -> q [Dec]
singBoundedInstance = singInstance mkBoundedInstance "Bounded"

singInstance :: DsMonad q
             => (DType -> [DCon] -> q UInstDecl)
             -> String -> Name -> q [Dec]
singInstance mk_inst inst_name name = do
  (tvbs, cons) <- getDataD ("I cannot make an instance of " ++ inst_name
                            ++ " for it.") name
  dtvbs <- mapM dsTvb tvbs
  dcons <- mapM dsCon cons
  raw_inst <- mk_inst (foldType (DConT name) (map tvbToType dtvbs)) dcons
  (a_inst, decs) <- promoteM [] $
                    promoteInstanceDec Map.empty raw_inst
  decs' <- singDecsM [] $ (:[]) <$> singInstD a_inst
  return $ decsToTH (decs ++ decs')

singInfo :: DsMonad q => DInfo -> q [DDec]
singInfo (DTyConI dec _) =
  singTopLevelDecs [] [dec]
singInfo (DPrimTyConI _name _numArgs _unlifted) =
  fail "Singling of primitive type constructors not supported"
singInfo (DVarI _name _ty _mdec _fixity) =
  fail "Singling of value info not supported"
singInfo (DTyVarI _name _ty) =
  fail "Singling of type variable info not supported"

singTopLevelDecs :: DsMonad q => [Dec] -> [DDec] -> q [DDec]
singTopLevelDecs locals raw_decls = do
  decls <- withLocalDeclarations locals $ expand raw_decls     -- expand type synonyms
  PDecs { pd_let_decs              = letDecls
        , pd_class_decs            = classes
        , pd_instance_decs         = insts
        , pd_data_decs             = datas }    <- partitionDecs decls

  ((letDecEnv, classes', insts'), promDecls) <- promoteM locals $ do
    promoteDataDecs datas
    (_, letDecEnv) <- promoteLetDecs noPrefix letDecls
    classes' <- mapM promoteClassDec classes
    let meth_sigs = foldMap (lde_types . cd_lde) classes
    insts' <- mapM (promoteInstanceDec meth_sigs) insts
    return (letDecEnv, classes', insts')

  singDecsM locals $ do
    let letBinds = concatMap buildDataLets datas
                ++ concatMap buildMethLets classes
    (newLetDecls, newDecls) <- bindLets letBinds $
                               singLetDecEnv letDecEnv $ do
                                 newDataDecls <- concatMapM singDataD datas
                                 newClassDecls <- mapM singClassD classes'
                                 newInstDecls <- mapM singInstD insts'
                                 return (newDataDecls ++ newClassDecls ++ newInstDecls)
    return $ promDecls ++ (map DLetDec newLetDecls) ++ newDecls

-- see comment at top of file
buildDataLets :: DataDecl -> [(Name, DExp)]
buildDataLets (DataDecl _nd _name _tvbs cons _derivings) =
  concatMap con_num_args cons
  where
    con_num_args :: DCon -> [(Name, DExp)]
    con_num_args (DCon _tvbs _cxt name fields) =
      (name, wrapSingFun (length (tysOfConFields fields))
                         (promoteValRhs name) (DConE $ singDataConName name))
      : rec_selectors fields

    rec_selectors :: DConFields -> [(Name, DExp)]
    rec_selectors (DNormalC {}) = []
    rec_selectors (DRecC fields) =
      let names = map fstOf3 fields in
      [ (name, wrapSingFun 1 (promoteValRhs name) (DVarE $ singValName name))
      | name <- names ]

-- see comment at top of file
buildMethLets :: UClassDecl -> [(Name, DExp)]
buildMethLets (ClassDecl { cd_lde = LetDecEnv { lde_types = meth_sigs } }) =
  map mk_bind (Map.toList meth_sigs)
  where
    mk_bind (meth_name, meth_ty) =
      ( meth_name
      , wrapSingFun (countArgs meth_ty) (promoteValRhs meth_name)
                                        (DVarE $ singValName meth_name) )

singClassD :: AClassDecl -> SgM DDec
singClassD (ClassDecl { cd_cxt  = cls_cxt
                      , cd_name = cls_name
                      , cd_tvbs = cls_tvbs
                      , cd_fds  = cls_fundeps
                      , cd_lde  = LetDecEnv { lde_defns = default_defns
                                            , lde_types = meth_sigs
                                            , lde_infix = fixities
                                            , lde_proms = promoted_defaults } }) = do
  (sing_sigs, _, tyvar_names, res_kis)
    <- unzip4 <$> zipWithM (singTySig no_meth_defns meth_sigs)
                           meth_names (map promoteValRhs meth_names)
  let default_sigs = catMaybes $ zipWith mk_default_sig meth_names sing_sigs
      res_ki_map   = Map.fromList (zip meth_names
                                       (map (fromMaybe always_sig) res_kis))
  sing_meths <- mapM (uncurry (singLetDecRHS (Map.fromList tyvar_names)
                                             res_ki_map))
                     (Map.toList default_defns)
  let fixities' = map (uncurry singInfixDecl) fixities
  cls_cxt' <- mapM singPred cls_cxt
  (kproxies, kproxy_pred) <- mkKProxies (map extractTvbName cls_tvbs)

  return $ DClassD (cls_cxt' ++ kproxy_pred)
                   (singClassName cls_name) kproxies
                   cls_fundeps   -- they are fine without modification
                   (map DLetDec (sing_sigs ++ sing_meths ++ fixities') ++ default_sigs)
  where
    no_meth_defns = error "Internal error: can't find declared method type"
    always_sig    = error "Internal error: no signature for default method"
    meth_names    = Map.keys meth_sigs

    mk_default_sig meth_name (DSigD s_name sty) =
      DDefaultSigD s_name <$> add_constraints meth_name sty
    mk_default_sig _ _ = error "Internal error: a singled signature isn't a signature."

    add_constraints meth_name sty = do  -- Maybe monad
      prom_dflt <- Map.lookup meth_name promoted_defaults
      let default_pred = foldl DAppPr (DConPr equalityName)
                               [ foldApply (promoteValRhs meth_name) tvs
                               , foldApply prom_dflt tvs ]
      return $ DForallT tvbs (default_pred : cxt) (ravel args res)
      where
        (tvbs, cxt, args, res) = unravel sty
        tvs                    = map tvbToType tvbs


singInstD :: AInstDecl -> SgM DDec
singInstD (InstDecl { id_cxt = cxt, id_name = inst_name
                    , id_arg_tys = inst_tys, id_meths = ann_meths }) = do
  cxt' <- mapM singPred cxt
  inst_kis <- mapM promoteType inst_tys
  meths <- concatMapM (uncurry sing_meth) ann_meths
  return (DInstanceD cxt'
                     (foldl DAppT (DConT s_inst_name) (map kindParam inst_kis))
                     meths)

  where
    s_inst_name = singClassName inst_name

    sing_meth :: Name -> ALetDecRHS -> SgM [DDec]
    sing_meth name rhs = do
      mb_info <- dsReify name
      ty <- case mb_info of
              Just (DVarI _ (DForallT cls_tvbs _cls_pred inner_ty) _ _) -> do
                let subst = Map.fromList (zip (map extractTvbName cls_tvbs)
                                              inst_tys)
                return (substType subst inner_ty)
              _ -> do
                info <- reifyWithLocals name
                decls <- localDeclarations
                fail $ "Cannot find type of method " ++ show name ++ "\nRAE " ++ show mb_info ++ "\n" ++ show info ++ "\n" ++ show decls
              -- TODO: also should look up sName, just in case
      (s_ty, _num_args, tyvar_names, res_ki) <- singType (promoteValRhs name) ty
      meth' <- singLetDecRHS (Map.singleton name tyvar_names)
                             (Map.singleton name res_ki)
                             name rhs
      return $ map DLetDec [DSigD (singValName name) s_ty, meth']

singLetDecEnv :: ALetDecEnv -> SgM a -> SgM ([DLetDec], a)
singLetDecEnv (LetDecEnv { lde_defns = defns
                         , lde_types = types
                         , lde_infix = infix_decls
                         , lde_proms = proms })
              thing_inside = do
  let prom_list = Map.toList proms
  (typeSigs, letBinds, tyvarNames, res_kis)
    <- unzip4 <$> mapM (uncurry (singTySig defns types)) prom_list
  let infix_decls' = map (uncurry singInfixDecl) infix_decls
      res_ki_map   = Map.fromList [ (name, res_ki) | ((name, _), Just res_ki)
                                                       <- zip prom_list res_kis ]
  bindLets letBinds $ do
    let_decs <- mapM (uncurry (singLetDecRHS (Map.fromList tyvarNames) res_ki_map))
                     (Map.toList defns)
    thing <- thing_inside
    return (infix_decls' ++ typeSigs ++ let_decs, thing)

singInfixDecl :: Fixity -> Name -> DLetDec
singInfixDecl fixity name
  | isUpcase name =
    -- is it a tycon name or a datacon name??
    -- it *must* be a datacon name, because symbolic tycons
    -- can't be promoted. This is terrible.
    DInfixD fixity (singDataConName name)
  | otherwise = DInfixD fixity (singValName name)

singTySig :: Map Name ALetDecRHS  -- definitions
          -> Map Name DType       -- type signatures
          -> Name -> DType   -- the type is the promoted type, not the type sig!
          -> SgM ( DLetDec               -- the new type signature
                 , (Name, DExp)          -- the let-bind entry
                 , (Name, [Name])        -- the scoped tyvar names in the tysig
                 , Maybe DKind           -- the result kind in the tysig
                 )
singTySig defns types name prom_ty =
  let sName = singValName name in
  case Map.lookup name types of
    Nothing -> do
      num_args <- guess_num_args
      (sty, tyvar_names) <- mk_sing_ty num_args
      return ( DSigD sName sty
             , (name, wrapSingFun num_args prom_ty (DVarE sName))
             , (name, tyvar_names)
             , Nothing )
    Just ty -> do
      (sty, num_args, tyvar_names, res_ki) <- singType prom_ty ty
      return ( DSigD sName sty
             , (name, wrapSingFun num_args prom_ty (DVarE sName))
             , (name, tyvar_names)
             , Just res_ki )
  where
    guess_num_args :: SgM Int
    guess_num_args =
      case Map.lookup name defns of
        Nothing -> fail "Internal error: promotion known for something not let-bound."
        Just (AValue _ n _) -> return n
        Just (AFunction _ n _) -> return n

      -- create a Sing t1 -> Sing t2 -> ... type of a given arity and result type
    mk_sing_ty :: Int -> SgM (DType, [Name])
    mk_sing_ty n = do
      arg_names <- replicateM n (qNewName "arg")
      return ( DForallT (map DPlainTV arg_names) []
                        (ravel (map (\nm -> singFamily `DAppT` DVarT nm) arg_names)
                               (singFamily `DAppT`
                                    (foldl apply prom_ty (map DVarT arg_names))))
             , arg_names )

singLetDecRHS :: Map Name [Name]
              -> Map Name DKind   -- result kind (might not be known)
              -> Name -> ALetDecRHS -> SgM DLetDec
singLetDecRHS _bound_names _res_kis name (AValue prom num_arrows exp) =
  DValD (DVarPa (singValName name)) <$>
  (wrapUnSingFun num_arrows prom <$> singExp exp)
singLetDecRHS bound_names res_kis name (AFunction prom_fun num_arrows clauses) =
  let tyvar_names = case Map.lookup name bound_names of
                      Nothing -> []
                      Just ns -> ns
      res_ki = Map.lookup name res_kis
  in
  DFunD (singValName name) <$>
        mapM (singClause prom_fun num_arrows tyvar_names res_ki) clauses

singClause :: DType   -- the promoted function
           -> Int     -- the number of arrows in the type. If this is more
                      -- than the number of patterns, we need to eta-expand
                      -- with unSingFun.
           -> [Name]  -- the names of the forall'd vars in the type sig of this
                      -- function. This list should have at least the length as the
                      -- number of patterns in the clause
           -> Maybe DKind   -- result kind, if known
           -> ADClause -> SgM DClause
singClause prom_fun num_arrows bound_names res_ki
           (ADClause var_proms pats exp) = do
  (sPats, prom_pats)
    <- mapAndUnzipM (singPat (Map.fromList var_proms) Parameter) pats
  let equalities = zip (map DVarT bound_names) prom_pats
      -- This res_ki stuff is necessary when we need to propagate result-
      -- based type-inference. It was inspired by toEnum. (If you remove
      -- this, that should fail to compile.)
      applied_ty = maybe id (\ki -> (`DSigT` ki)) res_ki $
                   foldl apply prom_fun prom_pats
  sBody <- bindTyVarsEq var_proms applied_ty equalities $ singExp exp
    -- when calling unSingFun, the prom_pats aren't in scope, so we use the
    -- bound_names instead
  let pattern_bound_names = zipWith const bound_names pats
       -- this does eta-expansion. See comment at top of file.
      sBody' = wrapUnSingFun (num_arrows - length pats)
                 (foldl apply prom_fun (map DVarT pattern_bound_names)) sBody
  return $ DClause sPats sBody'

-- we need to know where a pattern is to anticipate when
-- GHC's brain might explode
data PatternContext = LetBinding
                    | CaseStatement
                    | Parameter
                    deriving Eq

checkIfBrainWillExplode :: Monad m => PatternContext -> m ()
checkIfBrainWillExplode CaseStatement = return ()
checkIfBrainWillExplode Parameter = return ()
checkIfBrainWillExplode _ =
  fail $ "Can't use a singleton pattern outside of a case-statement or\n" ++
         "do expression: GHC's brain will explode if you try. (Do try it!)"

-- Note [No wildcards in singletons]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- We forbid patterns with wildcards during singletonization. Why? Because
-- singletonizing a pattern also must produce a type expression equivalent
-- to the pattern, for use in bindTyVars. Wildcards get in the way of this.
-- Thus, we de-wild patterns during promotion, and put the de-wilded patterns
-- in the ADExp AST.

singPat :: Map Name Name   -- from term-level names to type-level names
        -> PatternContext
        -> DPat
        -> SgM (DPat, DType) -- the type form of the pat
singPat _var_proms _patCxt (DLitPa _lit) =
  fail "Singling of literal patterns not yet supported"
singPat var_proms _patCxt (DVarPa name) = do
  tyname <- case Map.lookup name var_proms of
              Nothing     ->
                fail "Internal error: unknown variable when singling pattern"
              Just tyname -> return tyname
  return (DVarPa (singValName name), DVarT tyname)
singPat var_proms patCxt (DConPa name pats) = do
  checkIfBrainWillExplode patCxt
  (pats', tys) <- mapAndUnzipM (singPat var_proms patCxt) pats
  return ( DConPa (singDataConName name) pats'
         , foldl apply (promoteValRhs name) tys )
singPat var_proms patCxt (DTildePa pat) = do
  qReportWarning
    "Lazy pattern converted into regular pattern during singleton generation."
  singPat var_proms patCxt pat
singPat var_proms patCxt (DBangPa pat) = do
  (pat', ty) <- singPat var_proms patCxt pat
  return (DBangPa pat', ty)
singPat _var_proms _patCxt DWildPa =
  -- See Note [No wildcards in singletons]
  fail "Internal error: wildcard seen during singleton generation"

-- Note [Annotate case return type]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- We're straining GHC's type inference here. One particular trouble area
-- is determining the return type of a GADT pattern match. In general, GHC
-- cannot infer return types of GADT pattern matches because the return type
-- becomes "untouchable" in the case matches. See the OutsideIn paper. But,
-- during singletonization, we *know* the return type. So, just add a type
-- annotation. See #54.

-- Note [Why error is so special]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Some of the transformations that happen before this point produce impossible
-- case matches. We must be careful when processing these so as not to make
-- an error GHC will complain about. When binding the case-match variables, we
-- normally include an equality constraint saying that the scrutinee is equal
-- to the matched pattern. But, we can't do this in inaccessible matches, because
-- equality is bogus, and GHC (rightly) complains. However, we then have another
-- problem, because GHC doesn't have enough information when type-checking the
-- RHS of the inaccessible match to deem it type-safe. The solution: treat error
-- as super-special, so that GHC doesn't look too hard at singletonized error
-- calls. Specifically, DON'T do the applySing stuff. Just use sError, which
-- has a custom type (Sing x -> a) anyway.

singExp :: ADExp -> SgM DExp
  -- See Note [Why error is so special]
singExp (ADVarE err `ADAppE` arg)
  | err == errorName = DAppE (DVarE (singValName err)) <$> singExp arg
singExp (ADVarE name)  = lookupVarE name
singExp (ADConE name)  = lookupConE name
singExp (ADLitE lit)   = singLit lit
singExp (ADAppE e1 e2) = do
  e1' <- singExp e1
  e2' <- singExp e2
  return $ (DVarE applySingName) `DAppE` e1' `DAppE` e2'
singExp (ADLamE var_proms prom_lam names exp) = do
  let sNames = map singValName names
  exp' <- bindTyVars var_proms (foldl apply prom_lam (map (DVarT . snd) var_proms)) $
          singExp exp
  return $ wrapSingFun (length names) prom_lam $ DLamE sNames exp'
singExp (ADCaseE exp prom_exp matches ret_ty) =
    -- See Note [Annotate case return type]
  DSigE <$> (DCaseE <$> singExp exp <*> mapM (singMatch prom_exp) matches)
        <*> pure (singFamily `DAppT` ret_ty)
singExp (ADLetE env exp) =
  uncurry DLetE <$> singLetDecEnv env (singExp exp)
singExp (ADSigE {}) =
  fail "Singling of explicit type annotations not yet supported."

singMatch :: DType  -- ^ the promoted scrutinee
          -> ADMatch -> SgM DMatch
singMatch prom_scrut (ADMatch var_proms prom_match pat exp) = do
  (sPat, prom_pat)
    <- singPat (Map.fromList var_proms) CaseStatement pat
        -- why DAppT below? See comment near decl of ADMatch in LetDecEnv.
  let equality
        | DVarPa _ <- pat
        , (ADVarE err) `ADAppE` _ <- exp
        , err == errorName   -- See Note [Why error is so special]
        = [] -- no equality from impossible case.
        | otherwise      = [(prom_pat, prom_scrut)]
  sExp <- bindTyVarsEq var_proms (prom_match `DAppT` prom_pat) equality $
          singExp exp
  return $ DMatch sPat sExp

singLit :: Lit -> SgM DExp
singLit (IntegerL n)
  | n >= 0    = return $
                DVarE sFromIntegerName `DAppE`
                (DVarE singMethName `DSigE`
                 (singFamily `DAppT` DLitT (NumTyLit n)))
  | otherwise = do sLit <- singLit (IntegerL (-n))
                   return $ DVarE sNegateName `DAppE` sLit
singLit lit = do
  prom_lit <- promoteLitExp lit
  return $ DVarE singMethName `DSigE` (singFamily `DAppT` prom_lit)
