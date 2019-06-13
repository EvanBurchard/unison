{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.DeclPrinter where

import           Data.List                      ( isPrefixOf )
import           Data.Maybe                     ( fromMaybe )
import qualified Data.Map                      as Map
import           Unison.DataDeclaration         ( DataDeclaration'
                                                , EffectDeclaration'
                                                , toDataDecl
                                                )
import qualified Unison.DataDeclaration        as DD
import           Unison.HashQualified           ( HashQualified )
import qualified Unison.HashQualified          as HQ
import qualified Unison.Name                   as Name
import           Unison.NamePrinter             ( prettyHashQualified )
import           Unison.PrettyPrintEnv          ( PrettyPrintEnv )
import qualified Unison.PrettyPrintEnv         as PPE
import qualified Unison.Referent               as Referent
import           Unison.Reference               ( Reference )
import qualified Unison.Term                   as Term
import qualified Unison.Type                   as Type
import qualified Unison.TypePrinter            as TypePrinter
import           Unison.Util.Pretty             ( Pretty
                                                , ColorText
                                                )
import qualified Unison.Util.Pretty            as P
import           Unison.Var                     ( Var )
import qualified Unison.Var                    as Var

prettyEffectDecl
  :: Var v
  => PrettyPrintEnv
  -> Reference
  -> HashQualified
  -> EffectDeclaration' v a
  -> Pretty ColorText
prettyEffectDecl ppe r name = prettyGADT ppe r name . toDataDecl

prettyGADT
  :: Var v
  => PrettyPrintEnv
  -> Reference
  -> HashQualified
  -> DataDeclaration' v a
  -> Pretty ColorText
prettyGADT env r name dd = P.hang header . P.lines $ constructor <$> zip
  [0 ..]
  (DD.constructors' dd)
 where
  constructor (n, (_, _, t)) =
    prettyPattern env r name n
      <>       " :"
      `P.hang` TypePrinter.pretty env Map.empty (-1) t
  header = prettyEffectHeader name (DD.EffectDeclaration dd) <> " where"

prettyPattern
  :: PrettyPrintEnv -> Reference -> HashQualified -> Int -> Pretty ColorText
prettyPattern env r namespace n = prettyHashQualified
  ( HQ.stripNamespace (fromMaybe "" $ Name.toText <$> HQ.toName namespace)
  $ PPE.patternName env r n
  )

prettyDataDecl
  :: Var v
  => PrettyPrintEnv
  -> Reference
  -> HashQualified
  -> DataDeclaration' v a
  -> Pretty ColorText
prettyDataDecl env r name dd =
  (header <>) . P.sep (" | " `P.orElse` "\n  | ") $ constructor <$> zip
    [0 ..]
    (DD.constructors' dd)
 where
  constructor (n, (_, _, (Type.ForallsNamed' _ t))) = constructor' n t
  constructor (n, (_, _, t)                       ) = constructor' n t
  constructor' n t = case Type.unArrows t of
    Nothing -> prettyPattern env r name n
    Just ts -> case fieldNames env r name dd of
      Nothing -> P.group . P.hang' (prettyPattern env r name n) "      "
               $ P.spaced (TypePrinter.pretty0 env Map.empty 10 <$> init ts)
      Just fs -> P.group $ "{ "
                        <> P.sep ("," <> " " `P.orElse` "\n      ")
                                 (field <$> zip fs (init ts))
                        <> " }"
  field (fname, typ) = P.group $
    prettyHashQualified fname <> " :" `P.hang` TypePrinter.pretty0 env Map.empty (-1) typ
  header = prettyDataHeader name dd <> (" = " `P.orElse` "\n  = ")

-- Comes up with field names for a data declaration which has the form of a
-- record, like `type Pt = { x : Int, y : Int }`. Works by generating the
-- record accessor terms for the data type, hashing these terms, and then
-- checking the `PrettyPrintEnv` for the names of those hashes. If the names for
-- these hashes are:
--
--   `Pt.x`, `Pt.x.set`, `Pt.x.modify`, `Pt.y`, `Pt.y.set`, `Pt.y.modify`
--
-- then this matches the naming convention generated by the parser, and we
-- return `x` and `y` as the field names.
--
-- This function bails with `Nothing` if the names aren't an exact match for
-- the expected record naming convention.
fieldNames
  :: forall v a . Var v
  => PrettyPrintEnv
  -> Reference
  -> HashQualified
  -> DataDeclaration' v a
  -> Maybe [HashQualified]
fieldNames env r name dd = case DD.constructors dd of
  [(_, typ)] -> let
    vars :: [v]
    vars = [ Var.freshenId (fromIntegral n) (Var.named "_") | n <- [0..Type.arity typ - 1]]
    accessors = DD.generateRecordAccessors (map (,()) vars) (HQ.toVar name) r
    hashes = Term.hashComponents (Map.fromList accessors)
    names = [ (r, HQ.toString . PPE.termName env . Referent.Ref $ r)
            | r <- fst <$> Map.elems hashes ]
    fieldNames = Map.fromList
      [ (r, f) | (r, n) <- names
               , typename <- pure (HQ.toString name)
               , typename `isPrefixOf` n
               -- drop the typename and the following '.'
               , rest <- pure $ drop (length typename + 1) n
               , (f, rest) <- pure $ span (/= '.') rest
               , rest `elem` ["",".set",".modify"] ]
    in if Map.size fieldNames == length names then
         Just [ HQ.fromString name
              | v <- vars
              , Just (ref, _) <- [Map.lookup (Var.namespaced [HQ.toVar name, v]) hashes]
              , Just name <- [Map.lookup ref fieldNames] ]
       else Nothing
  _ -> Nothing

prettyModifier :: DD.Modifier -> Pretty ColorText
prettyModifier DD.Structural = mempty
prettyModifier (DD.Unique _uid) =
  P.hiBlack "unique" -- <> P.hiBlack ("[" <> P.text uid <> "] ")

prettyDataHeader :: Var v => HashQualified -> DD.DataDeclaration' v a -> Pretty ColorText
prettyDataHeader name dd =
  P.sepNonEmpty " " [
    prettyModifier (DD.modifier dd),
    P.hiBlue "type",
    P.blue (prettyHashQualified name),
    P.sep " " (P.text . Var.name <$> DD.bound dd) ]

prettyEffectHeader :: Var v => HashQualified -> DD.EffectDeclaration' v a -> Pretty ColorText
prettyEffectHeader name ed = P.sepNonEmpty " " [
  prettyModifier (DD.modifier (DD.toDataDecl ed)),
  P.hiBlue "ability",
  P.blue (prettyHashQualified name),
  P.sep " " (P.text . Var.name <$> DD.bound (DD.toDataDecl ed)) ]

prettyDeclHeader
  :: Var v
  => HashQualified
  -> Either (DD.EffectDeclaration' v a) (DD.DataDeclaration' v a)
  -> Pretty ColorText
prettyDeclHeader name (Left e) = prettyEffectHeader name e
prettyDeclHeader name (Right d) = prettyDataHeader name d
