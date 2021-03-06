{-# LANGUAGE
  FlexibleInstances,
  TypeFamilies,
  TemplateHaskell,
  DeriveFoldable,
  DeriveFunctor #-}
-- Copyright (c) JP Bernardy 2008
-- | Parser for haskell that takes in account only parenthesis and layout
module Yi.Syntax.Paren where

import Prelude hiding (elem)
import Control.Applicative
import Yi.IncrementalParse
import Yi.Lexer.Alex
import Yi.Lexer.Haskell
import Yi.Style (hintStyle, errorStyle, StyleName)
import Yi.Syntax.Layout
import Yi.Syntax.Tree
import Yi.Syntax
import Data.Foldable
import Data.Traversable
import Data.Monoid
import Data.Maybe

indentScanner :: Scanner (AlexState lexState) (TT)
              -> Scanner (Yi.Syntax.Layout.State Token lexState) (TT)
indentScanner = layoutHandler startsLayout [(Special '(', Special ')'),
                                            (Special '[', Special ']'),
                                            (Special '{', Special '}')] ignoredToken
                         (Special '<', Special '>', Special '.') isBrace

-- HACK: We insert the Special '<', '>', '.', that don't occur in normal haskell
-- parsing.

isBrace :: TT -> Bool
isBrace (Tok b _ _) = (Special '{') == b

ignoredToken :: TT -> Bool
ignoredToken (Tok t _ _) = isComment t || t == CppDirective

isNoise :: Token -> Bool
isNoise (Special c) = c `elem` ";,`"
isNoise _ = True

type Expr t = [Tree t]

data Tree t
    = Paren t (Expr t) t -- A parenthesized expression (maybe with [ ] ...)
    | Block ([Tree t])      -- A list of things separated by layout (as in do; etc.)
    | Atom t
    | Error t
    | Expr [Tree t]
      deriving (Show, Foldable, Functor)

instance IsTree Tree where
    emptyNode = Expr []
    uniplate (Paren l g r) = (g,\g' -> Paren l g' r)
    uniplate (Expr g) = (g,\g' -> Expr g')
    uniplate (Block s) = (s,\s' -> Block s')
    uniplate t = ([],\_ -> t)

-- | Search the given list, and return the 1st tree after the given
-- point on the given line.  This is the tree that will be moved if
-- something is inserted at the point.  Precondition: point is in the
-- given line.

-- TODO: this should be optimized by just giving the point of the end
-- of the line
getIndentingSubtree :: Tree TT -> Point -> Int -> Maybe (Tree TT)
getIndentingSubtree root offset line =
    listToMaybe $ [t | (t,posn) <- takeWhile ((<= line) . posnLine . snd) $ allSubTreesPosn,
                   -- it's very important that we do a linear search
                   -- here (takeWhile), so that the tree is evaluated
                   -- lazily and therefore parsing it can be lazy.
                   posnOfs posn > offset, posnLine posn == line]
    where allSubTreesPosn = [(t',posn) | t'@(Block _) <-filter (not . null . toList) (getAllSubTrees root),
                             let (tok:_) = toList t',
                             let posn = tokPosn tok]

-- | Given a tree, return (first offset, number of lines).
getSubtreeSpan :: Tree TT -> (Point, Int)
getSubtreeSpan tree = (posnOfs $ first, lastLine - firstLine)
    where bounds@[first, _last] = fmap (tokPosn . assertJust) [getFirstElement tree, getLastElement tree]
          [firstLine, lastLine] = fmap posnLine bounds
          assertJust (Just x) = x
          assertJust _ = error "assertJust: Just expected"

-- dropWhile' f = foldMap (\x -> if f x then mempty else Endo (x :))
--
-- isBefore l (Atom t) = isBefore' l t
-- isBefore l (Error t) = isBefore l t
-- isBefore l (Paren l g r) = isBefore l r
-- isBefore l (Block s) = False
--
-- isBefore' l (Tok {tokPosn = Posn {posnLn = l'}}) =


parse :: P TT (Tree TT)
parse = Expr <$> parse' tokT tokFromT

parse' :: (TT -> Token) -> (Token -> TT) -> P TT [Tree TT]
parse' toTok _ = pExpr <* eof
    where
      -- | parse a special symbol
      sym c = symbol (isSpecial [c] . toTok)

      pleaseSym c = (recoverWith errTok) <|> sym c

      pExpr :: P TT (Expr TT)
      pExpr = many pTree

      pBlocks = (Expr <$> pExpr) `sepBy1` sym '.' -- the '.' is generated by the layout, see HACK above
      -- note that we can have empty statements, hence we use sepBy1.

      pTree :: P TT (Tree TT)
      pTree = (Paren  <$>  sym '(' <*> pExpr  <*> pleaseSym ')')
          <|> (Paren  <$>  sym '[' <*> pExpr  <*> pleaseSym ']')
          <|> (Paren  <$>  sym '{' <*> pExpr  <*> pleaseSym '}')

          <|> (Block <$> (sym '<' *> pBlocks <* sym '>')) -- see HACK above

          <|> (Atom <$> symbol (isNoise . toTok))
          <|> (Error <$> recoverWith (symbol (isSpecial "})]" . toTok)))

      -- note that, by construction, '<' and '>' will always be matched, so
      -- we don't try to recover errors with them.

getStrokes :: Point -> Point -> Point -> Tree TT -> [Stroke]
getStrokes point _begin _end t0 = -- trace (show t0)
                                  result
    where getStrokes' (Atom t) = one (ts t)
          getStrokes' (Error t) = one (modStroke errorStyle (ts t)) -- paint in red
          getStrokes' (Block s) = getStrokesL s
          getStrokes' (Expr g) = getStrokesL g
          getStrokes' (Paren l g r)
              | isErrorTok $ tokT r = one (modStroke errorStyle (ts l)) <> getStrokesL g
              -- left paren wasn't matched: paint it in red.
              -- note that testing this on the "Paren" node actually forces the parsing of the
              -- right paren, undermining online behaviour.
              | (posnOfs $ tokPosn $ l) == point || (posnOfs $ tokPosn $ r) == point - 1

               = one (modStroke hintStyle (ts l)) <> getStrokesL g <> one (modStroke hintStyle (ts r))
              | otherwise  = one (ts l) <> getStrokesL g <> one (ts r)
          getStrokesL = foldMap getStrokes'
          ts = tokenToStroke
          result = appEndo (getStrokes' t0) []
          one x = Endo (x :)


tokenToStroke :: TT -> Stroke
tokenToStroke = fmap tokenToStyle . tokToSpan

modStroke :: StyleName -> Stroke -> Stroke
modStroke f = fmap (f `mappend`)

tokenToAnnot :: TT -> Maybe (Span String)
tokenToAnnot = sequenceA . tokToSpan . fmap tokenToText


-- | Create a special error token. (e.g. fill in where there is no correct token to parse)
-- Note that the position of the token has to be correct for correct computation of
-- node spans.
errTok :: Parser (Tok t) (Tok Token)
errTok = mkTok <$> curPos
   where curPos = tB <$> lookNext
         tB Nothing = maxBound
         tB (Just x) = tokBegin x
         mkTok p = Tok (Special '!') 0 (startPosn {posnOfs = p})

