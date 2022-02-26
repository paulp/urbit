module Practice.DependentHoon3 where

import ClassyPrelude hiding (even, find)

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Function ((&))
import Data.Set (isSubsetOf)
import Data.Void

import Practice.HoonCommon

-- | Desugared hoon. As a rough overview, the compiler pipeline is:
--
--   Hoon  ---open--->  Soft  ---------play--->  Code, Type
--                      Soft, Type  ---work--->  Code
--                                                | \
--                                                |  ---mint--->  Nock
--                                                \
--                                                 ---eval---> Base
--
-- The Soft type allows all wings, while the Code type allows only raw axes and
-- arm pulls. In this way, name resolution and type checking is separated from
-- code generation (and, very importantly, from compile-time interpretation,
-- where we would otherwise suffer horribly because the fully winged language is
-- not Liskov compliant).
--
-- If you like, you can think of the play/work step as performing a further,
-- type-directed desugaring step at the same time as it infers/checks types.
-- In addition to resolving wings, this step also removes casts and eliminates
-- patterns.
--
data Soft
  = Wng Wing
  | Atm Atom Grit Aura
  | Cns Soft Soft
  | Lam Pelt Soft
  | Fac Pelt Soft
  --
  | Plu Soft
  | Sla Soft Soft
  | Equ Soft Soft
  --
  | Bas Bass
  | Cll Soft Soft
  | Gat Soft Soft
  --
  | Wit Soft Soft
  | Pus Soft Soft
  | Net { sof :: Soft, typ :: Soft }
  | Cat { sof :: Soft, typ :: Soft }
  deriving (Eq, Ord, Show, Generic)

-- | A desugared skin; i.e., a pattern. Depending on embedding context, a pelt
-- is either "irrefutable" or "refutable." A pattern is *irrefutable* if it will
-- always match a value of the given type. Some positions in the desugared ast
-- require their patterns to be irrefutable. These locations are the left sides
-- of |= Lam and ^= Fac, i.e. the pelt applying faces to the input arg of a gate
-- and the pattern applying faces to the product of an expression. The only
-- location that permits you to use refutable pattern in the desugared ast is
-- left hand side of a ?= Fis. Both kinds of pelt give rise to face information,
-- which is stored in the Face constructor of Code. Refutable patterns
-- additionally give rise to "fishing" information, represented as a Fish, which
-- is ultimately compiled to pattern matching code in the output Nock.
-- The pipeline for processing pelts is:
--
--   Refutable flow:
--     Pelt ---------rompRe---> [Face], (Map Face Axis), Type
--     Pelt, Type ---toilRe---> [Face], (Map Face Axis))
--
--   Irrefutable flow:
--     Pelt ---------rompIr---> Fish, [Face], (Map Face Axis), Type
--     Pelt, Type ---toilIr---> Fish, [Face], (Map Face Axis)
--
--   Reverse flow:
--     Fish, [Face], (Map Face Axis) ---bask---> Pelt  [not implemented yet]
--
-- To understand the [Face] and (Map Face Axis), consider the following,
-- admittedly convoluted example:
--
--   ^=  a=b=[c d]=[e f g]=h  my-favorite-hoon
--
-- This will process to [a,b,h] {c -> +2, d -> +3, e -> +2, f -> +6, g -> +7}.
--
data Pelt
  = Punt            -- ^ _     wildcard
  | Peer Term       -- ^ a     variable
  | Part Soft       -- ^ %foo  constant
  | Pair Pelt Pelt  -- ^ []    cons
  | Pons Pelt Pelt  -- ^ a=    as-pattern
  | Pest Pelt Soft  -- ^ /   patern nest
  -- | Past (Pelt a) (Code a)  -- ^ ``  pattern cast
  deriving (Eq, Ord, Show, Generic)

-- | A hoon which has been stripped of all non-computational content, and which
-- is ready for evaluation or translation to Nock.
--
-- The type is parametrized to allow (stuck) references to outer subjects during
-- evaluation and nest checking (but not Nock translation).
data Code a
  = Stub Stub
  | Fore a
  --
  | Atom Atom
  | Cons (Code a) (Code a)
  | Lamb (Code a)
  --
  | Plus (Code a)
  | Slam (Code a) (Code a)
  | Test (Code a) (Code a) (Code a)
  | Fish Fish Axis  -- Do not allow direct fishing for arm pulls; cf 140?
  --
  | Aura Aura
  | Fork (Set Atom) Aura
  | Cell (Code a) (Code a)
  | Gate (Code a) (Code a)
  | Face Face (Code a)
  | Noun
  | Void
  | Type
  --
  | With (Code a) (Code a)
  | Push (Code a) (Code a)
  deriving (Functor, Foldable, Traversable, Generic)

deriving instance Show a => Show (Code a)

-- | Air-chilled wing. In the course of type checking, a Code with ordinary
-- wings in it, such as a.b, is translated into on where those wings have been
-- resolved to axes, e.g. +6. The exception is that if the leftmost limb in a
-- wing is determined to refer to an arm of a core, we leave it in place, but
-- resolve the core location into an axis. Thus the two kinds of Stubs
-- correspond to Nock 0 and 9. The change from wing to stub is one of the core
-- differences between Soft and Code. It is because of this change that Code
-- satisfies the Liskov substitution principle while Soft does not, which is
-- why Code is suitable for evaluation (and Soft isn't).
data Stub
  = Leg Axis
  -- | Arm Axis Term (Set Term)
  deriving (Eq, Ord)

instance Show Stub where
  show = \case
    Leg a -> "+" <> show a

-- | A layer of facial information on a type or annotating a value to change its
-- type.
--
-- A "blocking face" or "mask" is an ordinary hoon face with the poperties you
-- are familiar with. If you are looking for face f and you encounter mask g
-- (g /= f), then your search does not go into the current subtree and instead
-- skips over it, moving sideways. This is what we mean by "blocking."
--
-- A "non-blocking alias" or "link" is an extra name for an axis in the current
-- subtree that doesn't interfere with any names inside. If the face you're
-- looking for matches a link, you're done. On the other hand, if it doesn't,
-- you still proceed deep into the current subtree to look for it anyway. If
-- the link does match, the semantics are that you go to that axis, *strip off
-- any masks present*, then apply the list of faces to the outside.
--
-- Links are based on an idea of Joe for improving tistar, and may in fact be
-- used to implement tistar eventually.
data Face
  = Mask Term                       -- ^ blocking face
  | Link (Map Term (Axis, [Face]))  -- ^ non-blocking alias
  deriving (Eq, Ord, Show, Generic)

-- | Computational content of a refutable pattern. All you need to know to
-- check for match at nock/eval time.
data Fish
  = Tuna            -- ^ definite match
  | Sole Atom       -- ^ equality match
  | Char Fish Fish  -- ^ cellular match
  deriving (Eq, Ord, Show, Generic)

-- | The system of "levels," analogous to de Bruijn levels, allows for a stable
-- way of referring to part of the subject, even as the subject continues to
-- grow to the right. The checker tracks the "current level" of the subject, L.
-- Then the pair (lvl, ax) is interpreted as the raw Axis peg(2^(L - lvl), ax).
-- You can think of (lvl, ax) as representing an axis grounded at the leftmost
-- node of depth L, rather than grounded at the root as in ordinary axes: You
-- walk up lvl steps from that leftmost node, then go down according to ax in
-- the usual way. This system allows us to avoid retraversing the subject type
-- every time the subject grows to rewrite stuck axes, which would ultimately be
-- quadratic. (What is a stuck axis for? It's a reference into a part of the the
-- subject for which the seminoun stores no information. For example, if a gate
-- takes a type argument, and in the body of that gate we want to construct a
-- list of that type, it'd be a (list +6), where "+6" is an opaque reference
-- into the seminoun that, in nest checking, compares equal only to itself
-- (which is all that we mean when we say "opaque reference"). The point of the
-- level system is to avoid having to grow that +6 when we tislus something new.
type Level = Nat

-- | Frozen wing.
data Rump
  = Leg' (Level, Axis)
  -- | Arm' (Level, Axis) Term (Set Term)

instance Show Rump where
  show = \case
    Leg' (l, a) -> "+" <> show l <> "_" <> show a

-- | Check whether two leveled axes correspond to the same axis. Because I'm too
-- stupid right now, the current encoding of leveled axes has duplicate reprs.
even :: (Level, Axis) -> (Level, Axis) -> Bool
even (l, a) (m, b)
  | l < m     = peg (2 ^ (m - l)) a == b
  | l > m     = a == peg (2 ^ (l - m)) b
  | otherwise = a == b

instance Eq Rump where
  Leg' la == Leg' lb = even la lb

-- | Code with wings fully resolved to axes.
type Cold = Code Stub

-- | Increase the number of formal wings permitted when passing under a tisgar,
-- allowing types to refer opaquely to parts of the seminoun of the old subject.
-- These outer wings are NOT permitted in user code, NOR do they have
-- computational meaning; rather, they just sit around stuck to serve as things
-- we track the equality of in the nest checker. For example, suppose your gate
-- takes in a type, then you construct a (list +6), then you tisgar it. The type
-- of the subject is now (list "^+6"), which uses an outer reference.
-- Incidentally, there is now no way for the user to write this type down inside
-- the tisgar; this is fine because there also isn't a way to construct the
-- runtime type information inside either. If you want these things, you should
-- have tisgared more info.
data Hop b a
  = New b  -- ^ reference to current subject
  | Old a  -- ^ reference to outer subject
  deriving (Functor, Foldable, Traversable, Generic)

instance (Show a, Show b) => Show (Hop a b) where
  show = \case
    New x -> show x
    Old y -> show y <> "^"

deriving instance (Eq a, Eq b) => Eq (Hop a b)

-- | Alias useful for pedagogical purposes.
type Type = Base

-- | In Base, a common pattern is a closure, suspended over some copy of the
-- subject, and awaiting an extra value before execution can continue. The copy
-- of the subject (think of the context of the result of executing a |%) is
-- paired with the code to execute once the payload is inflated. But often we
-- already have a constant Base we wish to put in this spot, e.g. if the type is
-- not dependent. Thus, a second case provides for this here, for performance.
data Bind a
  = Bind (Base a) {- ^ closed-over subject -} (Code (Hop Stub a))
  | Base (Base a) {- ^ constant -}
  deriving (Functor, Foldable, Traversable)

-- | Fully evaluated expression, possibly stuck on opaque values / symbols in
-- a. These can be thought of as constants, in the sense that if converted back
-- up to code via `loft`, the result will be a code which is "position
-- independent", and does not have any wings into the current subject. FIXME
-- last sentence.
data Base a
  = Rump' Rump
  | Fore' a
  --
  | Atom' Atom
  | Cons' (Base a) (Base a)
  | Lamb' (Base a) {- ^ closed-over subject -} (Code a)
  --
  | Plus' (Base a)
  | Slam' (Base a) (Base a)
  | Look' (Base a) Stub
  --
  | Aura' Aura
  | Fork' (Set Atom) Aura
  | Cell' (Type a) (Base a) {- ^ closed-over subject -} (Code a)
  | Gate' (Type a) (Base a) {- ^ closed-over subject -} (Code a)
  | Face' Face (Base a)
  | Noun'
  | Void'
  | Type'
  deriving (Functor, Foldable, Traversable, Generic)

deriving instance Show a => Show (Base a)


-- Compile-time evaluator ------------------------------------------------------

-- | Read a value back into code, with reference to the current level.
loft :: Level -> Base a -> Code a
loft lvl = \case
  -- XX we should have some printout here if lvl < l, which is a serious
  -- invariant violation that should be more legible
  Rump' (Leg' (l, a)) -> Stub (Leg $ peg (2 ^ (lvl - l)) a)
  Fore' x -> Fore x
  --
  Atom' a -> Atom a
  Cons' a b -> Cons (loft lvl a) (loft lvl b)
  -- NOTE Kovacs has the rule `VLam x t -> Lam x (quote (l + 1) (t $$ VVar l))`
  -- corresponding to our
  --   Lamb' s a ->
  --     Lamb $ loft (l + 1) $ eval (Cons' s $ Stop' (Leg' (l + 1, 3))) a
  -- but I think that our With allows us to skip the inner eval
  -- XX decide whether this is true and prudent.
  -- Also notice the practice of lofting a level higher under a binder, e.g. in
  -- Kovacs `VPi x a b -> Pi x (quote l a) (quote (l + 1) (b $$ VVar l))`.
  -- If my understanding is correct, this single difference is the way in which
  -- subject oriented programming is easier to understand than de Bruijn.
  --
  Lamb' s a -> Lamb $ luft lvl s a -- With (loft lvl s) $ Lamb a
  --
  Plus' a -> Plus (loft lvl a)
  Slam' a b -> Slam (loft lvl a) (loft lvl b)
  Look' a s -> With (loft lvl a) $ Stub s
  --
  Aura' au -> Aura au
  Fork' as au -> Fork as au
  -- previously With (loft lvl s) $ Cell (loft lvl t) c, but this made test
  -- output unpleasant. Same with gate
  Cell' t s c -> Cell (loft lvl t) (luft lvl s c)
  Gate' t s c -> Gate (loft lvl t) (luft lvl s c)
  Face' fs b -> Face fs (loft lvl b)
  Noun' -> Noun
  Void' -> Void
  Type' -> Type
 where
  luft l sub cod = loft (l + 1) $ eval (Cons' sub $ Rump' (Leg' (l + 1, 3))) cod

-- | Axially project a value; i.e. implement Nock 0 or 9.
look :: Stub -> Base a -> Base a
look s b = home s $ walk a b
 where
  a = case s of
    Leg a -> a

  walk a b = case (cut a, b) of
    (Nothing,     c)                   -> c
    (_,           Rump' (Leg' (l, x))) -> Rump' $ Leg' (l, peg x a)
    (_,           Look' c (Leg i))     -> Look' c $ Leg (peg i a)
    (_,           Face' _ c)           -> walk a c
    (Just (L, b), Cons' c _)           -> walk b c
    (Just (R, b), Cons' _ c)           -> walk b c
    (Just _,      _)                   -> Look' b s

  home s b = case s of
    Leg _ -> b

-- | Given a seminoun representing the subject, evaluate code into a seminoun
-- product.
eval :: Base a -> Code a -> Base a
eval sub = \case
  Stub s -> look s sub
  Fore x -> Fore' x
  --
  Atom a -> Atom' a
  Cons c d -> Cons' (eval sub c) (eval sub d)
  Lamb a -> Lamb' sub a
  --
  -- Note that elimination forms must explicitly look for and strip Faces.
  Plus c -> go (eval sub c)
   where
    go = \case
      Face' _ b -> go b
      Atom' a -> Atom' (a + 1)
      b -> Plus' b
  Slam c d -> go (eval sub c)
   where
    go = \case
      Face' _ b -> go b
      -- TODO replace with gold core thing
      Lamb' s c -> eval (Cons' s $ eval sub d) c
      b -> Slam' b (eval sub d)
  --
  Aura au -> Aura' au
  Fork as au -> Fork' as au
  Cell c d -> Cell' (eval sub c) sub d
  Gate c d -> Gate' (eval sub c) sub d
  Face fs c -> Face' fs (eval sub c)
  Noun -> Noun'
  Void -> Void'
  Type -> Type'
  --
  With c d -> eval (eval sub c) d
  Push c d -> eval (Cons' sub $ eval sub c) d

-- | Take typechecking result, which will lack Fore and evaluate it against
-- subject with arbitrary Fores. In a subtyping language, this would not be
-- necessary.
evil :: Base a -> Code Void -> Base a
evil ken = eval ken . vacuous


-- The type checking monad -----------------------------------------------------

type Var a = (Eq a, Show a)

class (Monad m, Alternative m) => MonadCheck m where
  -- | Push an error reporting stack frame.
  act :: Act -> m a -> m a

  -- | Report an error.
  bail :: Fail -> m a

  -- | Change the error message of the error, if any, that occurs within the
  -- computation.
  bailSwap :: (Fail -> Fail) -> m a -> m a

  -- | Leave a message to be embedded in the trace. Has no effect in non-tracing
  -- modes.
  note :: Note -> m ()

-- | Fail with no message.
bailFail :: MonadCheck m => m a
bailFail = bail BailFail

-- | Error reporting context, analogous to stack trace item. As the compiler
-- recurses deeper into its operations, it pushes these descriptions to a stack
-- so they can serve as breadcrumbs in error messages.
data Act
  =                     ActRoot
  | forall a. Show a => ActFits Fit (Type a) (Type a)
  | forall a. Show a => ActFind (Con a) Wing
  | forall a. Show a => ActMeld (Base a) (Base a)
  | forall a. Show a => ActFuse (Con a) (Base a, Type a) Pelt
  | forall a. Show a => ActCrop (Con a) (Type a) Pelt
  |                     ActFish Pelt
  | forall a. Show a => ActToil (Con a) Fit Pelt (Type a)
  | forall a. Show a => ActRomp (Con a) Pelt
  | forall a. Show a => ActWork (Con a) Fit Soft (Type a)
  | forall a. Show a => ActPlay (Con a) Soft
  |                     ActDone

-- | Compiler errors.
data Fail
  -- | Invariant violation: unknown seminoun on exiting tisgar.
  = forall a. Show a => PareFree Rump (Base (Hop Rump a))
  -- | Cannot locate the given ally in the subject.
  | forall a. Show a => FindFail Term (Type a)
  -- | The two types do not {nest, cast, equal each other}.
  | forall a. Show a => FitsFail Fit (Type a) (Type a)
  -- | While fusing, cannot merge equality onto seminoun.
  | forall a. Show a => MeldFail (Base a) (Base a)
  -- | During fuse, pattern not compatible with expected type.
  | forall a. Show a => FuseFail (Base a, Type a) Pelt
  -- | It is not acceptable to cast/nest in pelts you are fishing with.
  | FuseFits Fit
  -- | During crop, pattern not compatible with expected type.
  | forall a. Show a => CropFail (Type a) Pelt
  -- | It is not acceptable to cast/nest in pelts you are fishing with.
  | CropFits Fit
  -- | Equality patterns not supported in fish. XX
  | FishSame Soft
  -- | Pike is less delicious to eat than the other kinds of fish.
  | FishPike Pelt Pelt
  -- | Your pelt performs a test, which is not permitted in this context.
  | forall a. Show a => ToilFish Pelt (Type a)
  -- | Your pelt performs a test, which is not permitted in this context.
  | RompPart Soft
  -- | Please add extra casts/nests to your pelt; we cannot infer the type.
  | RompWild Pelt
  -- | You are trying to slam something which is not a gate.
  | forall a. Show a => NeedGate (Type a)
  | BailNote Text  -- ^ failure with note
  | BailFail  -- ^ unspecified failure

-- | Log items. Appear only in trace mode.
data Note
  = forall a. Var a => NoteType Text (Type a)
  | forall a. Var a => NoteBase Text (Base a)
  | forall a. Var a => NoteCode Text (Code a)

instance Semigroup Fail where
  f <> _ = f  -- report first failure

instance Monoid Fail where
  mempty = BailNote "mempty"

deriving instance (Show Act)
deriving instance (Show Fail)
deriving instance (Show Note)

-- | Basic type checking monad.
newtype Check a = Check { unCheck :: ReaderT [Act] (Either ([Act], Fail)) a }
  deriving newtype (Functor, Applicative, Monad)

-- | Run the computation in basic type checking mode
runCheck :: Check a -> Either ([Act], Fail) a
runCheck chk = runReaderT (unCheck chk) []

instance Alternative Check where
  empty = bailFail
  Check (ReaderT c) <|> Check (ReaderT d) = Check $ ReaderT \r -> c r <> d r

instance MonadCheck Check where
  act a chk = Check $ local (a:) (unCheck chk)
  bail f = Check $ ask >>= \as -> lift $ Left (as, f)
  bailSwap f chk = Check $ ReaderT \r -> case runReaderT (unCheck chk) r of
    Left (acts, err) -> Left (acts, f err)
    Right x -> Right x
  note _ = pure ()

data ActTree
  = ActTree Act [ActTree]  -- ^ most recent act at front
  | ActNote Note
  deriving Show

type Trace a = ExceptT Fail (State [ActTree]) a

runTrace :: Trace a -> (ActTree, Either Fail a)
runTrace tac = (tree zipper, res)
 where
  (res, zipper) = runState (runExceptT tac) [ActTree ActRoot []]

  tree zz = foldl' insertTree (ActTree ActDone []) zz

insertTree :: ActTree -> ActTree -> ActTree
insertTree inner _outer@(ActTree a cs) = ActTree a (inner : cs)

instance MonadCheck (ExceptT Fail (State [ActTree])) where
  act a m = do
    modify' (ActTree a [] :)
    res <- m
    modify' \(inner:outer:rest) -> insertTree inner outer : rest
    pure res
  bail = throwError
  bailSwap f m = catchError m (\e -> throwError (f e))
  note n = modify' \(outer:rest) -> insertTree (ActNote n) outer : rest


traceToStack :: ActTree -> [Act]
traceToStack = reverse . go
 where
  go = \case
    ActTree ActDone [] -> []
    ActTree a [] -> [a]
    ActTree ActRoot (t:_) -> go t
    ActTree a (t:_) -> a : go t


-- Context management ----------------------------------------------------------

-- | What we know about the subject
data Con a = Con
  { lvl :: Level   -- ^ number of =+s we have passed under since =>
  , sut :: Type a  -- ^ type of the subject
  , ken :: Base a  -- ^ seminoun of current subject
  }

deriving instance (Show a) => Show (Con a)

-- | Grow the subject without knowledge, using an unevaluated type
hide :: Con a -> Code a -> Con a
hide Con{lvl, sut, ken} x = Con
  { lvl = lvl + 1
  , sut = Cell' sut ken x
  , ken = Cons' ken $ Rump' (Leg' (lvl + 1, 3))
  }

-- | Grow the subject without knowledge
hide' :: Con a -> Type a -> Con a
hide' Con{lvl, sut, ken} t = Con
  { lvl = lvl + 1
  , sut = Cell' sut ken $ loft (lvl + 1) t
  , ken = Cons' ken $ Rump' (Leg' (lvl + 1, 3))
  }

-- | Grow the subject with knowledge
shew :: Con a -> Base a -> Type a -> Con a
shew Con{lvl, sut, ken} b t = Con
  { lvl = lvl + 1
  , sut = Cell' sut ken $ loft (lvl + 1) t
  , ken = Cons' ken b
  }

-- | Grow the type because we have passed under a tisgar
grow :: Type a -> Type (Hop Rump a)
grow = \case
  Rump' r -> Fore' (New r)
  Fore' x -> Fore' (Old x)
  --
  Atom' a -> Atom' a
  Cons' x y -> Cons' (grow x) (grow y)
  Lamb' x c -> Lamb' (grow x) (crow c)
  --
  Plus' x -> Plus' (grow x)
  Slam' x y -> Slam' (grow x) (grow y)
  Look' x st -> Look' (grow x) st
  --
  Aura' au -> Aura' au
  Fork' as au -> Fork' as au
  Cell' x y c -> Cell' (grow x) (grow y) (crow c)
  Gate' x y c -> Gate' (grow x) (grow y) (crow c)
  Face' fs x -> Face' fs (grow x)
  Noun' -> Noun'
  Void' -> Void'
  Type' -> Type'

 where
  crow :: Code a -> Code (Hop Rump a)
  crow = \case
    -- lookups into the closure are NOT changed; this is okay because the stuck
    -- seminoun references in the value in the clousre ARE.
    Stub st -> Stub st
    Fore x -> Fore (Old x)
    --
    Atom a -> Atom a
    Cons c d -> Cons (crow c) (crow d)
    Lamb c -> Lamb (crow c)
    --
    Plus c -> Plus (crow c)
    Slam c d -> Slam (crow c) (crow d)
    --
    Aura au -> Aura au
    Fork as au -> Fork as au
    Cell c d -> Cell (crow c) (crow d)
    Gate c d -> Gate (crow c) (crow d)
    Face fs c -> Face fs (crow c)
    Noun -> Noun
    Void -> Void
    Type -> Type
    --
    With c d -> With (crow c) (crow d)
    Push c d -> Push (crow c) (crow d)

-- | On exiting a tisgar, pare down the type to remove any opaque references to
-- the inner subject, but actually it's an invariant violation for any to exist.
pare :: (MonadCheck m, Show a) => Base (Hop Rump a) -> m (Base a)
pare bas = go bas
 where
  go = \case
    Rump' r -> bail (PareFree r bas)
    Fore' (New r) -> pure $ Rump' r
    Fore' (Old x) -> pure $ Fore' x
    --
    Atom' a -> pure $ Atom' a
    Cons' x y -> Cons' <$> go x <*> go y
    Lamb' x c -> Lamb' <$> go x <*> care c
    --
    Plus' x -> Plus' <$> go x
    Slam' x y -> Slam' <$> go x <*> go y
    Look' x st -> flip Look' st <$> go x
    --
    Aura' au    -> pure $ Aura' au
    Fork' as au -> pure $ Fork' as au
    Cell' x y c -> Cell' <$> go x <*> go y <*> care c
    Gate' x y c -> Gate' <$> go x <*> go y <*> care c
    Face' fs x -> Face' fs <$> go x
    Noun' -> pure Noun'
    Void' -> pure Void'
    Type' -> pure Type'

  care :: (MonadCheck m, Show a) => Code (Hop Rump a) -> m (Code a)
  care = \case
    -- This stays put because it's actually an axis into the stored closure.
    Stub st -> pure $ Stub st
    Fore (New r) -> bail (PareFree r bas)
    Fore (Old x) -> pure $ Fore x
    --
    Atom a -> pure $ Atom a
    Cons c d -> Cons <$> care c <*> care d
    Lamb c -> Lamb <$> care c
    --
    Plus c -> Plus <$> care c
    Slam c d -> Slam <$> care c <*> care d
    --
    Aura au -> pure $ Aura au
    Fork as au -> pure $ Fork as au
    Cell c d -> Cell <$> care c <*> care d
    Gate c d -> Gate <$> care c <*> care d
    Face fs c -> Face fs <$> care c
    Noun -> pure Noun
    Void -> pure Void
    Type -> pure Type
    --
    With c d -> With <$> care c <*> care d
    Push c d -> Push <$> care c <*> care d

-- | Construct a nondependent cell type. Thinking of providing this "freely"
-- as another constructor under Cell for efficiency. Make sure you know your
-- cell type is nondependent before attempting this!
--
-- The only difference between dependent and nondependent cells here is that we
-- loft below at lvl, rather than lvl + 1. XX think hard about this and test!
cell' :: Con a -> Base a -> Base a -> Base a
cell' Con{lvl, ken} l r = Cell' l ken $ loft lvl r

face :: [Face] -> Code a -> Code a
face fs b = foldr Face b fs

face' :: [Face] -> Base a -> Base a
face' fs b = foldr Face' b fs


-- Axial operations ------------------------------------------------------------

data Step = L | R
  deriving (Eq, Ord, Show)

hop :: Step -> Axis -> Axis
hop L = peg 2
hop R = peg 3

peg :: Axis -> Axis -> Axis
peg a = \case
  0 -> error "zero axis"  -- I guess? the hoon diverges
  1 -> a
  2 -> a * 2
  3 -> a * 2 + 1
  b -> b `mod` 2 + peg a (b `div` 2) * 2

-- | Combo of cap and mas. FIXME name change.
cut :: Axis -> Maybe (Step, Axis)
cut = \case
  0 -> error "zero axis"
  1 -> Nothing
  2 -> Just (L, 1)
  3 -> Just (R, 1)
  a -> let Just (s, b) = cut (a `div` 2)
       in Just (s, a `mod` 2 + b * 2)

run :: Axis -> [Step]
run = map fst . pop

-- | Really very sorry
pop :: Axis -> [(Step, Axis)]
pop a = case cut a of
  Nothing -> []
  Just (s, a') -> (s, a) : pop a'

pole :: Axis -> Stub -> Stub
pole a = \case
  Leg b -> Leg (peg a b)


--------------------------------------------------------------------------------
-- Core operations of the compiler ---------------------------------------------
--------------------------------------------------------------------------------

-- The calculus of types -------------------------------------------------------

-- | Mode for fit-checking in `fits`: nest, cast, or exact equality.
data Fit
  = FitSame  -- ^ perform a type (or value) equivalence check
  | FitNest  -- ^ perform a subtyping check
  | FitCast  -- ^ perform a coercibility check; i.e. ignore auras
  deriving (Eq, Ord, Generic)

instance Show Fit where
  show = \case
    FitCast -> "cast"
    FitNest -> "nest"
    FitSame -> "same"

-- | Perform subtyping, coercibility, or equality check.
-- XX figure out proper encoding of recursion via cores or gates
-- XX figure out how seminouns should apply here, if at all
fits :: forall a m. (MonadCheck m, Var a)
     => Fit -> Type a -> Type a -> m ()
fits fit t u = act (ActFits fit t u) case (t, u) of
  (Face' _ v, w) -> fits fit v w
  (v, Face' _ w) -> fits fit v w

  (Noun', Noun') -> pure ()
  (Noun', _) -> fitsFail
  (_, Noun') -> case fit of
    FitSame -> fitsFail
    FitNest -> pure ()
    FitCast -> pure ()

  (Void', Void') -> pure ()
  (Void', _) -> case fit of
    FitSame -> fitsFail
    FitNest -> pure ()
    FitCast -> pure ()
  (_, Void') -> fitsFail

  (Rump' r, Rump' s)
    | r == s    -> pure ()
    | otherwise -> fitsFail
  (Rump'{}, _) -> fitsFail
  (_, Rump'{}) -> fitsFail

  (Fore' r, Fore' s)
    | r == s    -> pure ()
    | otherwise -> fitsFail
  (Fore'{}, _) -> fitsFail
  (_, Fore'{}) -> fitsFail

  -- XX confirm this, but I do think we have to decide definitional equality
  -- of terms as part of nest. E.g. Suppose someone has opaquely defined
  -- vect/$-(@ $ $) in their context. Because it's opaque, we cannot rely on
  -- inlining the definition in the context of nest checking. Thus to decide
  -- (vect 1 @) <?= (vect 1 *), we must determine that vect and vect are the
  -- same variable, 1 and 1 are the same term, and @ <= *.
  --
  -- But the above has a serious problem. Is vect covariant or contravariant?
  -- The rule implied above implicitly treats all such "opaque type functions"
  -- as covariant which is WRONG. Absent some variance marking solution,
  -- these should presumably be regarded as invariant.
  --
  -- To make invariance work, the proposed solution is to add a third Fit mode
  -- FitSame which does equality rather than subtyping, and switch to it under
  -- eliminators such as Slam (XX and other eliminators and introductors?).
  --
  (Atom' a, Atom' b) | a == b -> pure ()
  (Atom'{}, _) -> fitsFail
  (_, Atom'{}) -> fitsFail

  (Cons' v w, Cons' v' w') -> do fits fit v v'; fits fit w w'
  (Cons'{}, _) -> fitsFail
  (_, Cons'{}) -> fitsFail

  -- Evaluate the function bodies against a fresh opaque symbol. To get a fresh
  -- symbol, we have a bunch of options:
  --   - Track level as an argument to fits, as Kovacs does, incrementing under
  --     binders. We can then use (lvl + 1, 3) as the new Rump. Downside: not
  --     clear how to get this value when comparing two RTTIs at runtime.
  --     Although, in fact, rtts wil NEVER have rumps, so...
  --   - Possibly, store a level in each saved, closed over, subject, taking the
  --     larger of the two. Think hard about whether this actually works.
  --   - Use Bound library style bullshit. Change the `a` type argument to allow
  --     an extra variable. This is a bit weird because the Codes are actually
  --     Hop Stub a, and bases have an extra Rump in them (so they are kinda
  --     Hop Rump a, except we couldn't get away with literally doing that), so
  --     we have to insert the variable just under the top level. But it works.
  --     On the other hand in a strict language paying the fmap cost upfront is
  --     not great? But we know for a fact that we'll be processing the entire
  --     body on success anyway, so? But also subtyping means if we're clever
  --     we can avoid fmapping entirely, if a can be encoded such that it's a
  --     subtype of Hop Stub a.
  --
  (Lamb'{}, Lamb'{}) -> fits fit (eval (Cons' s new) c) (eval (Cons' z new) d)
   where
    new = Fore' (New ())
    Lamb' s c = fmap Old t
    Lamb' z d = fmap Old u

  (Lamb'{}, _) -> fits fit (eval (Cons' s new) c) (Slam' x new)
   where
    new = Fore' (New ())
    Lamb' s c = fmap Old t
    x = fmap Old u

  (_, Lamb'{}) -> fits fit (Slam' x new) (eval (Cons' z new) d)
   where
    new = Fore' (New ())
    x = fmap Old t
    Lamb' z d = fmap Old u

  -- Elimination forms. Note that since Base, we will only encounter these
  -- "stuck" on some variable, possibly nested.
  (Plus' v, Plus' w) -> fits fit v w
  (Plus'{}, _) -> fitsFail
  (_, Plus'{}) -> fitsFail

  -- Since it hasn't been evaluated away, we are dealing with an opaque type
  -- function application. This means we have no choice but to regard the
  -- function as invariant in its argument.
  (Slam' v w, Slam' v' w') -> do fits fit v v'; fits FitSame w w'
  (Slam'{}, _) -> fitsFail
  (_, Slam'{}) -> fitsFail

  -- The assumption is that these are fully evaluated. This rules out Looks
  -- stacked on top of Looks, as well of Looks on top of cells. Accordingly the
  -- rules are pretty tight. I don't think there's any equiv of the beta-eta
  -- conversion we saw above with functions here.
  (Look' b st, Look' c ub)
    | st == ub  -> fits fit b c
    | otherwise -> fitsFail
  (Look'{}, _) -> fitsFail
  (_, Look'{}) -> fitsFail

  (Aura' au, Aura' ag) -> case fit of
    FitCast -> pure ()
    FitNest -> if ag `isPrefixOf` au then pure () else fitsFail
    FitSame -> if ag ==           au then pure () else fitsFail

  (Fork' cs au, Aura' ag) | fit /= FitSame -> fits @a fit (Aura' au) (Aura' ag)

  (Fork' cs au, Fork' ds ag) -> do
    fits @a fit (Aura' au) (Aura' ag)
    case fit of
      FitSame -> when (cs /= ds) fitsFail
      FitNest -> unless (cs `isSubsetOf` ds) fitsFail
      FitCast -> unless (cs `isSubsetOf` ds) fitsFail

  (Cell' v _ _, Cell' w _ _) -> do
    fits fit v w
    let
      fresh = New ()
      Cell' _ s c = fmap Old t
      Cell' _ z d = fmap Old u
    -- use the smaller type to do case analysis, if applicable
    for_ (cases fresh u) \cas ->
      fits fit
        (eval (Cons' s cas) c)
        (eval (Cons' z cas) d)

  (Gate' v _ _, Gate' w _ _) -> do
    -- Recall that the argument to a gate is contravariant
    fits fit w v
    let
      fresh = New ()
      Gate' _ s c = fmap Old t
      Gate' _ z d = fmap Old u
    -- use the smaller type to do case analysis, if applicable
    for_ (cases fresh w) \cas ->
      fits fit
        (eval (Cons' s cas) c)
        (eval (Cons' z cas) d)

  (Type', Type') -> pure ()

  (Aura'{}, _) -> fitsFail
  (_, Aura'{}) -> fitsFail
  (Fork'{}, _) -> fitsFail
  (_, Fork'{}) -> fitsFail
  (Cell'{}, _) -> fitsFail
  (_, Cell'{}) -> fitsFail
  (Gate'{}, _) -> fitsFail
  (_, Gate'{}) -> fitsFail


 where
  fitsFail = bail (FitsFail fit t u)

  -- For "finite" types, instead of generating a fresh variable, produce all
  -- the "cases" of that type. This could be generalized in a bunch of ways:
  --   - atoms: generate [0, +(<fresh>)]
  --   - cells of finite types
  -- The compiler accordingly does "case analysis" for cell and gate types,
  -- implementing the proper rules for $% nesting as a special case.
  cases :: b {- ^ fresh variable supply -} -> Type a -> [Base b]
  cases var = \case
    Aura' _ -> [Fore' var]  -- or: [Atom' 0 Sand au, Plus' (Fore' var)]?
    -- This is the case we need to make $% work.
    Fork' cs au -> fmap Atom' $ toList cs
    -- NOTE it is actually possible to do something cool here, but it would
    -- require constructing an infinite, splittable fresh variable supply.
    Cell' t s c -> [Fore' var]
    -- It is absolutely infeasable to enumerate all gates
    Gate'{} -> [Fore' var]
    -- Also an important case
    Face' _ t -> cases var t
    Noun' -> [Fore' var]
    Void' -> [Fore' var]
    Type' -> [Fore' var]
    -- The below will actually occur: e.g. stuck variables, applications
    _ -> [Fore' var]


-- Find ------------------------------------------------------------------------

-- | Zipper on the subject to return from find. That way if you edit the subject
-- at that point you can put it back together.
data Line a = Line
  { llv :: Level
  , lem :: Base a
  , lyt :: Type a
  , sez :: [SemiLayer a]
  , tez :: [TypeLayer a]
  }

data SemiLayer a
  = SeL (Base a)           -- ^ [_ b]
  | SeR (Base a)           -- ^ [b _]
  | SeF [Face]             -- ^ f=_

data TypeLayer a
  = TyL (Base a) (Code a)  -- ^ =>  b  {_ c}
  | TyR (Base a) (Base a)  -- ^ =>  c  {b _}
  | TyF [Face]             -- ^ f=_

-- TODO
-- 1. Write seal :: Line a -> Con a
-- 2. Edit find to return a Line
-- 3. Write crop and fuse.

{-
seal :: Line a -> Con a
seal Line{llv, lem, lyt, sez, tez} = case (sez, tez) of
  ([], []) -> Con{lvl=llv, ken=lem, sut=lyt}
  (sel:sez, _) -> case sel of
    SeL b -> seal Line{llv, lem=(Cons' lem b), lyt, sez, tez}
    SeR b -> seal Line{llv, lem=(Cons' b lem), lyt, sez, tez}
    SeF f -> seal Line{llv, lem=(Face' f lem), lyt, sez, tez}
  (_, tel:tez) -> case tel of
    -- XX we should maybe do simul traverse, eta beta to inline new seminoun
    -- into the right of the cell type. In Cell-Rail hoon, Rails become Cells
    -- here.
    TyL s c -> seal Line{llv, lem, lyt=(Cell' lyt s c), sez, tez}
    TyR b   -> seal Line{llv, lem, lyt=(Cell' b lyt),   sez, tez}  -- XX ?
    TyF f   -> seal Line{llv, lem, lyt=(face' f lyt),   sez, tez}
-}

-- | Strip faces and combine adjacent rumps.
repo :: Var a => Base a -> Base a
repo = \case
  Face' _ b -> repo b
  -- Cons' b c -> case (repo b, repo c) of
  --  (Rump' (Leg' (l, a)), Rump' (Leg' (m, b)))
  --    | Just (n, c) <- conj (l, a) (m, b) -> Rump' $ Leg' (n, c)
  --  (x, y) -> Cons' x y
  -- Noun' -> Both' (Aura' "") $ Cell' Noun' (Atom' 0 Rock "") Noun'
  b -> b
 -- where
 --  conj :: (Level, Axis) -> (Level, Axis) -> Maybe (Level, Axis)
 --  conj (l, a) (m, b)
 --    | l < m                 = conj (m, peg (2 ^ (m - l)) a) (m, b)
 --    | l > m                 = conj (l, a) (l, peg (2 ^ (l - m)) b)
 --    | Just (L, x) <- cut a
 --    , Just (R, y) <- cut b
 --    , a == b                = Just (l, a `div` 2)
 --    | otherwise             = Nothing


-- | Resolve the names in a Wing, producing the type of that part of the subject
-- and an axial representation of the wing.
find :: forall a m. (MonadCheck m, Var a)
     => Con a -> Wing -> m (Stub, Type a)
find sub@Con{lvl, sut, ken} win = act (ActFind sub win) do
  (st, Con{sut}) <- fond sub win
  pure (st, sut)
 where
  fond :: Con a -> Wing -> m (Stub, Con a)
  fond con@Con{lvl, sut, ken} = \case
    [] -> pure (Leg 1, con)
    l:ls -> fond sub ls >>= \case
      -- (_, Arm{}) -> bail undefined  -- arm must occur leftmost
      (Leg a, con) -> do
        (st, con) <- limb con l
        pure (pole a st, con)

  limb :: Con a -> Limb -> m (Stub, Con a)
  limb con = \case
    Axis a -> (Leg a,) <$> axis con a
    Ally f -> ally con f

  -- XX what should meaningfully happen with lvl here? or should we strip it out
  axis :: Con a -> Axis -> m (Con a)
  axis con@Con{sut, ken} a = case (cut a, sut) of
    (Nothing,     _)           -> pure con
    (_,           Face' _ t)   -> axis con{sut=t} a
    (Just (L, a), Cell' t _ _) -> axis con{sut=t, ken=(look (Leg 2) ken)} a
    -- XX under what circumstances will it be the case that we have an equation
    -- for the value of the head, but this knowledge is not inlined into the tail?
    (Just (R, a), Cell' _ s c) -> let hd = look (Leg 2) ken
                                      tl = look (Leg 3) ken
                                      ty = eval (Cons' s hd) c
                                  in  axis con{sut=ty, ken=tl} a
    -- XX an old note reads: "arguably for Liskov, should be Noun :("; rethink
    (_,           _)           -> bailFail

  ally :: Var a => Con a -> Term -> m (Stub, Con a)
  ally con@Con{sut} f = maybe (bail $ FindFail f sut) id $ lope con
   where
    lope :: Con a -> Maybe (m (Stub, Con a))
    lope con@Con{sut, ken} = case sut of
      Face' (Mask m) t
        | f == m    -> Just $ pure (Leg 1, con{sut=t})
        | otherwise -> Nothing
      Face' (Link ls) t
        | Just (a, fs) <- lookup f ls -> Just $ (Leg a,) <$> axis con a
        | otherwise                   -> lope con{sut=t}

      Cell' t s c -> asum
        -- NB: We look to the right first, because =+ now pushes to the right.
        [ let hd = look (Leg 2) ken
              tl = look (Leg 3) ken
              ty = eval (Cons' s hd) c
          in fmap (first (pole 3)) <$> lope con{sut=ty, ken=tl}
        ,    fmap (first (pole 2)) <$> lope con{sut=t,  ken=(look (Leg 2) ken)}
        ]

      -- Gold/Lead

      _ -> Nothing


-- Pelt system -----------------------------------------------------------------

-- | Strip masks, but not links, from outside of type.
clip :: Type a -> Type a
clip = \case
  Face' Mask{} t -> t
  Face' l@Link{} t -> Face' l t
  t -> t

-- | Upgrade outer mask to link.
clop :: [Face] -> Map Term (Axis, [Face])
clop = \case
  [] -> mempty
  Mask m : fs -> mapFromList [(m, (1, fs))]
  Link ls : fs -> fmap (second (++ fs)) ls

-- | Peg an axis onto every axis in a link.
clap :: Axis -> Map Term (Axis, [Face]) -> Map Term (Axis, [Face])
clap a = fmap \(b, fs) -> (peg a b, fs)

-- | Extract the non-computational content from a pelt (i.e. the faces).
derm :: Pelt -> [Face]
derm = \case
  Punt -> []
  Peer m -> [Mask m]
  Part _ -> []
  Pair p q -> [Link $ clap 2 (clop (derm p)) ++ clap 3 (clop (derm q))]
  Pons p q -> derm p ++ derm q
  Pest p _ -> derm p

-- | Verify that a pattern is irrefutable TODO.
tofu :: MonadCheck m
     => Pelt -> m ()
tofu = undefined

-- | Extract the computational content from a pelt (i.e. the testing part).
fish :: forall m. MonadCheck m => Pelt -> m Fish
fish fis = act (ActFish fis) case fis of
  Punt -> pure Tuna
  Peer _ -> pure Tuna
  Part (Atm a _ _) -> pure $ Sole a
  Part s -> bail (FishSame s)
  Pair p q -> char <$> fish p <*> fish q
  Pons p q -> do
    h <- fish p
    j <- fish q
    bailSwap (const $ FishPike p q) $ pike h j
  Pest p _ -> fish p
 where
  -- conjunction of fishes
  pike :: Fish -> Fish -> m Fish
  pike Tuna h = pure h
  pike h Tuna = pure h
  pike (Char h j) (Char k l) = Char <$> pike h k <*> pike j l
  pike (Sole a) (Sole b) | a == b = pure $ Sole a
  pike (Sole _) _ = bailFail
  pike _ (Sole _) = bailFail

  -- product of fishes
  char :: Fish -> Fish -> Fish
  char Tuna Tuna = Tuna
  char h    j    = Char h j

{-
-- | Merge pelt onto seminoun.
meld :: Var a => Base a -> Pelt -> Check (Base a)
meld sem pet = act (ActMeld sem pet) case pet of
  Punt -> pure sem
  Peer _ -> pure sem
  Part (Atm a g au) -> case {- repo -} sem of
    -- XX arguably should accumulate "equality constraints" e.g. suppose we have
    --   =+  a=...
    --   =+  b=a
    --   ?:  ?=(%foo b)
    -- we should learn that both b and a are %foo in the yes branch.
    -- XX should we also do matching on Fore's?
    Rump' _ -> pure $ Atom' a g au
    Atom' a' g' au' | a == a' -> pure $ Atom' a g au  -- XX g au
    _ -> bail (MeldFail sem pet)
  Part s ->
    -- XX no support yet for equality patterns
    bail (MeldSame sem s)
  Pair p q -> Cons' <$> meld (look (Leg 2) sem) p <*> meld (look (Leg 3) sem) q
  Pons p q -> do b <- meld sem q; meld b p  -- right happens first
  Pest p _ -> meld sem p
-}

-- | Merge two seminouns. XX eventually this should accumulate "equality
-- constraints" which can be piped into fits as extra assumptions.
meld :: (MonadCheck m, Var a) => Base a -> Base a -> m (Base a)
meld b c = case (repo b, repo c) of
  (Rump'{},   a)                      -> pure a
  (a,         Rump'{})                -> pure a
  (Cons' b c, Cons' b' c')            -> Cons' <$> meld b b' <*> meld c c'
  (Atom' a,   Atom' b)      | a == b  -> pure $ Atom' a
  _                                   -> bail (MeldFail b c)

-- | Refine scrutinee type and seminoun on the assumption that the pelt matches.
fuse :: forall a m. (MonadCheck m, Var a)
     => Con a -> (Base a, Type a) -> Pelt -> m (Base a, Type a)
fuse con@Con{lvl, ken} (b, t) pet = act (ActFuse con (b, t) pet) case pet of
  Punt -> pure (b, t)
  Peer _ -> pure (b, t)
  Part s -> do
    (x, t') <- play con s
    fits FitNest t' t
    (, t') <$> meld b (evil ken x)
  Pair p q -> case repo t of
    Cell' t s c -> do
      let x = look (Leg 2) b
      let y = look (Leg 3) b
      (x', t') <- fuse con (x, t) p
      (y', u') <- fuse con (y, eval (Cons' s x) c) q
      pure (Cons' x' y', Cell' t' ken $ loft lvl u')
    _ -> bail (FuseFail (b, t) pet)
  Pons p q -> do (b, t) <- fuse con (b, t) q; fuse con (b, t) p
  Pest _ _ -> bail (FuseFits FitNest)

-- | Refine scrutinee type on the assumption that pelt does NOT match.
crop :: forall a m. (MonadCheck m, Var a)
     => Con a -> Type a -> Pelt -> m (Type a)
crop con@Con{lvl, ken} t pet = act (ActCrop con t pet) case pet of
  Punt -> pure Void'
  Peer _ -> pure Void'
  Part s -> do
    -- seems bad that this check duplicates fuse
    work con FitNest s t
    case (s, repo t) of
      (Atm a g au, Fork' as au') -> pure $ Fork' (deleteSet a as) au'  -- XX au
      (_, t) -> pure t
  Pair p q -> case repo t of
    Cell' t s c -> do
      t' <- crop con t p
      u <- crop con (eval s c) q
      fis <- fish q
      let c' = Test (Fish fis 3) (loft lvl u) c
      pure $ Cell' t' s c'
    _ -> bail (CropFail t pet)
  Pons p q -> do t <- crop con t q; crop con t p
  Pest _ _ -> bail (FuseFits FitNest)


-- | Given a pattern, verify that it is compatibile with the given type.
-- Produce a new, broader type corresponding to any upcasts we may have made.
-- This type will not have faces. To get the faces, run derm.
toil :: (MonadCheck m, Var a)
     => Con a -> Fit -> Pelt -> Base a -> Type a -> m (Type a)
toil con@Con{ken, lvl} fit pet sem typ = act (ActToil con fit pet typ)
 case pet of
  Punt -> pure typ
  Peer f -> pure typ
  Part s -> case (s, repo typ) of
    -- NOTE support for this is the only thing blocking merge of toil and romp
    -- (romp would be toil against Noun once we have $@ and repo), and then
    -- we would test that the fish is Tuna to check irrefutability. I guess
    -- another idea would be for fish to make use of type info to avoid unnec
    -- testing. Uhh, that seems way better?
    -- XX the above comment seems wrong. Yes, it should be Void, not Noun.
    -- Also XX Void needs to be accepted in a lot of places, like Slam head...
    (Atm a Rock au, Fork' as ag) | setToList as == [a] -> pure typ
    _ -> bail (ToilFish pet typ)
  Pair p q -> case repo typ of
    Cell' t s c -> do
      let x = look (Leg 2) sem
      let y = look (Leg 3) sem
      u <- toil con fit p x t
      -- you could demand a seminoun be passed in to do this more aggro ugh
      v <- toil con fit q y (eval (Cons' s x) c)
      pure (Cell' u ken $ loft (lvl + 1) v)
    _ -> bail (ToilFish pet typ)
  Pons p q -> toil con fit p sem =<< toil con fit q sem typ
  Pest p c -> do
    x <- work con FitNest c Type'
    let t = evil ken x
    -- Important: the type is reversed here. In this sense, pelts are
    -- contravariant.
    fits fit typ t
    toil con FitNest p sem t

-- | Return the nest-largest type compatible with a pattern, along with
-- information on the masking and non-masking faces it applies
romp :: (MonadCheck m, Var a)
     => Con a -> Pelt -> m (Type a)
romp con@Con{ken, lvl} pet = act (ActRomp con pet) case pet of
  Punt -> bail (RompWild pet)
  Peer _ -> bail (RompWild pet)
  Part c -> do (x, t) <- play con c; pure t
  Pair p q -> do
    t <- romp con p
    let fs = derm p
    -- XX I think this hide is ok only for lam, but also romp only lam :/
    u <- romp (hide' con $ face' fs t) q
    pure (Cell' t ken $ loft (lvl + 1) u)
  Pons p q -> do
    t <- romp con q
    toil con FitNest p (Rump' $ Leg' (lvl + 1, 3)) t
  Pest p c -> do
    x <- work con FitNest c Type'
    toil con FitNest p (Rump' $ Leg' (lvl + 1, 3)) (evil ken x)


-- Type checking ---------------------------------------------------------------

-- | Given subject type and knowledge, verify that code has result type.
-- Since the expected result type is known in this mode, we can lighten the
-- user's annotation burden, e.g. on |= argument. Read about "bidirectional type
-- checking" to learn more.
work :: forall a m. (MonadCheck m, Var a)
     => Con a -> Fit -> Soft -> Type a -> m (Code Void)
work con@Con{lvl, sut, ken} fit cod typ = act (ActWork con fit cod typ)
  let playFits = do (x, t') <- play con cod
                    fits fit t' typ
                    pure x
  in case cod of
    Wng{} -> playFits

    -- for introduction forms except atoms, we push the type constraint inward
    -- this allows the user to type-annotate the whole of a big data structure
    -- indcluding cores and gates, without having to also annotate the insides
    -- unless they want to.
    Atm{} -> playFits

    -- XX not using cas-rule `want` functions here because I don't think it's
    -- appropriate to propagate in enCased type ascriptions here, but maybe
    -- I should rethink.
    --     Also, notice how we propagate the fit mode inward. This allows for
    -- "deep casts" e.g. `$-(@ @)`|=(a/@u +(a)). Pretty, but unsure if
    -- desirable yet.
    Cns c d -> case typ of
      Face' fs t -> work con fit cod t
      Cell' t sub e -> do
        x <- work con fit c t
        let u = eval (Cons' sub $ evil ken x) e
        y <- work con fit d u
        pure (Cons x y)
      _ -> playFits

    Lam p c -> case typ of
      Face' fs t -> work con fit cod t
      Gate' t sub e -> do
        t' <- toil con fit p (Rump' $ Leg' (lvl + 1, 3)) t
        let fs = derm p
        let can = hide' con $ face' fs t'
        let u = eval (Cons' sub $ Rump' $ Leg' (lvl + 1, 3)) e
        y <- work can fit c u
        pure (Lamb y)
      _ -> playFits

    Fac p c -> do
      -- XX think about whether we should instead play here, so that toil can
      -- operate against a more specific scrutinee type.
      x <- work con fit c typ
      -- XX It's strictly wrong to use typ here; we should use the result of
      -- playing c. But playing c could fail, so...
      _ <- toil con fit p (evil ken x) typ
      let fs = derm p
      pure (face fs x)

    -- elimination forms just use nest
    Plu{} -> playFits
    Sla{} -> playFits
    Equ{} -> playFits

    -- likewise with types
    Bas{} -> playFits
    Cll{} -> playFits
    Gat{} -> playFits
    --Gold{} -> playFits
    --Lead{} -> playFits

    Wit c d -> do
      (x, t) <- play con c
      let kan = evil ken x
      y <- work Con{lvl=0, sut=(grow t), ken=(grow kan)} fit d (grow typ)
      pure $ With x y

    Pus c d -> do
      (x, t) <- play con c
      work (shew con (evil ken x) t) fit d typ

    Net{} -> playFits
    Cat{} -> playFits

-- | Require the given type to be a function type.
-- XX Deppy had a cas rule here; why?
needGate :: (MonadCheck m, Var a)
         => Con a -> Type a -> m (Type a, Base a, Code a)
needGate con = \case
  Gate' t s c -> pure (t, s, c)
  Face' _ t -> needGate con t
  t -> bail $ NeedGate t

-- | Given subject type and knowledge, determine product type of code
play :: forall a m. (MonadCheck m, Var a)
     => Con a -> Soft -> m (Code Void, Type a)
play con@Con{lvl, sut, ken} cod = act (ActPlay con cod) case cod of
  Wng w -> do
    (st, t) <- find con w
    pure (Stub st, t)

  Atm a Rock t -> pure (Atom a, Fork' (singleton a) t)

  Atm a Sand t -> pure (Atom a, Aura' t)

  Cns c d -> do
    (x, t) <- play con c
    (y, u) <- play con d
    -- XX the below invocation appears identical to "constructing a nondependent
    -- cell". Think hard about this.
    pure (Cons x y, Cell' t ken (loft (lvl + 1) u))

  Lam p c -> do
    -- TODO replace with gold core
    t <- romp con p
    let fs = derm p
    (x, u) <- play (hide' con $ face' fs t) c
    pure (Lamb x, Gate' t ken (loft (lvl + 1) u))

  Fac p c -> do
    (x, t) <- play con c
    t' <- toil con FitNest p (evil ken x) t
    let fs = derm p
    -- XX think about under what circumstances we can strip the first face.
    -- It's annoying to have these lying around in the seminoun.
    pure (face fs x, face' fs t')

  Plu c -> do
    -- Following 140, we do not propagate aura.
    x <- work con FitNest c (Aura' "")
    pure (Plus x, Aura' "")

  Sla c d -> do
    (x, ct) <- play con c
    (at, s, rc) <- needGate con ct
    y <- work con FitNest d at
    pure (Slam x y, eval (Cons' s $ evil ken y) rc)

  Equ c d -> undefined

  Bas (Aur au) -> pure (Aura au, Type')

  Bas Flg -> pure (Fork (setFromList [0, 1]) "f", Type')

  Bas Nul -> pure (Fork (setFromList [0]) "n", Type')

  Bas (Fok as au) -> pure (Fork (setFromList as) au, Type')

  Bas Cel -> pure (Cell Noun Noun, Type')

  Cll c d -> do
    x <- work con FitNest c Type'
    y <- work (hide con (vacuous x)) FitNest d Type'
    pure (Cell x y, Type')

  Gat c d -> do
    x <- work con FitNest c Type'
    y <- work (hide con (vacuous x)) FitNest d Type'
    pure (Gate x y, Type')

  Bas Non -> pure (Noun, Type')

  Bas Vod -> pure (Void, Type')

  Bas Typ -> pure (Type, Type')

  Wit c d -> do
      (x, t) <- play con c
      let kan = evil ken x
      (y, u) <- play Con{lvl=0, sut=(grow t), ken=(grow kan)} d
      ret <- pare u
      pure (With x y, ret)

  Pus c d -> do
    (x, t) <- play con c
    (y, u) <- play (shew con (evil ken x) t) d
    pure (Push x y, u)

  Net{sof, typ} -> do
    x <- work con FitNest typ Type'
    let t = evil ken x
    y <- work con FitNest sof t
    pure (y, t)

  Cat{sof, typ} -> do
    x <- work con FitNest typ Type'
    let t = evil ken x
    y <- work con FitCast sof t
    pure (y, t)

-- | Read code back to soft, making no attempt to untranslate axes to wings with
-- names.
rest :: forall a m. Show a => Code a -> Soft
rest = \case
  Stub (Leg a) -> Wng [Axis a]
  Fore x -> Wng [Ally $ tshow @(Hop () a) $ Old x]  -- hack for printing
  --
  Atom a -> Atm a Sand (heuAura a)
  Cons c d -> Cns (rest c) (rest d)
  -- XX this loss of facial information may be unfortunate for diagnostic
  -- purposes. Think about this. Fixed by doze?
  Lamb c -> Lam Punt (rest c)
  --
  Plus c -> Plu (rest c)
  Slam c d -> Sla (rest c) (rest d)
  --
  Aura au -> Bas (Aur au)
  Fork as "f" | as == setFromList [0, 1] -> Bas Flg
  Fork as au -> Bas (Fok (toList as) au)
  Cell Noun Noun -> Bas Cel
  Cell c d -> Cll (rest c) (rest d)
  Gate c d -> Gat (rest c) (rest d)
  Face (Mask m) c -> Fac (Peer m) (rest c)
  Face (Link ls) c -> Fac Punt (rest c)  -- FIXME ?
  Noun -> Bas Non
  Void -> Bas Vod
  Type -> Bas Typ
  With c d -> Wit (rest c) (rest d)
  Push c d -> Pus (rest c) (rest d)

-- | Use a subject type to read back wing information in a much less shitty way.
doze :: Var a => Type a -> Code Stub -> Soft
doze typ = undefined
