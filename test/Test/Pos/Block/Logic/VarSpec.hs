-- | Specification of 'Pos.Block.Logic.VAR'.

module Test.Pos.Block.Logic.VarSpec
       ( spec
       ) where

import           Universum
import           Unsafe                    (unsafeHead)

import           Data.List                 (span)
import           Data.List.NonEmpty        (NonEmpty ((:|)))
import qualified Data.List.NonEmpty        as NE
import           Serokell.Util             (throwText)
import           Test.Hspec                (Spec, describe)
import           Test.Hspec.QuickCheck     (modifyMaxSuccess, prop)
import           Test.QuickCheck.Monadic   (assert, pre)

import           Pos.Block.Logic           (verifyAndApplyBlocks, verifyBlocksPrefix)
import           Pos.Block.Types           (Blund)
import           Pos.DB.Pure               (DBPureVar)
import qualified Pos.GState                as GS
import           Pos.Ssc.GodTossing        (SscGodTossing)
import           Pos.Util                  (lensOf)
import           Pos.Util.Chrono           (NE, OldestFirst (..))

import           Test.Pos.Block.Logic.Mode (BlockProperty, BlockTestMode)
import           Test.Pos.Block.Logic.Util (bpGenBlocks, bpGoToArbitraryState,
                                            satisfySlotCheck)
import           Test.Pos.Util             (splitIntoChunks, stopProperty)

spec :: Spec
-- Unfortunatelly, blocks generation is quite slow nowdays.
-- See CSL-1382.
spec = describe "Block.Logic.VAR" $ modifyMaxSuccess (min 12) $ do
    describe "verifyBlocksPrefix" verifyBlocksPrefixSpec
    describe "verifyAndApplyBlocks" verifyAndApplyBlocksSpec
    describe "applyBlocks" applyBlocksSpec

----------------------------------------------------------------------------
-- verifyBlocksPrefix
----------------------------------------------------------------------------

verifyBlocksPrefixSpec :: Spec
verifyBlocksPrefixSpec = do
    prop verifyEmptyMainBlockDesc verifyEmptyMainBlock
    prop verifyValidBlocksDesc verifyValidBlocks
  where
    verifyEmptyMainBlockDesc =
        "verification of consistent empty main block " <>
        "created by the leader of the 0-th slot " <>
        "always succeeds for initial GState"
    verifyValidBlocksDesc =
        "verification of (hopefully) valid blocks " <>
        "generated by the block generator " <>
        "always succeeds for GState for which these blocks where generated " <>
        "as long as all these blocks are from the same epoch"

verifyEmptyMainBlock :: BlockProperty ()
verifyEmptyMainBlock = do
    -- unsafeHead is safe here, because we explicitly request to
    -- generate exactly 1 block
    emptyBlock <- fst . unsafeHead . getOldestFirst <$> bpGenBlocks (Just 1)
    whenLeftM (lift $ verifyBlocksPrefix (one emptyBlock)) stopProperty

verifyValidBlocks :: BlockProperty ()
verifyValidBlocks = do
    bpGoToArbitraryState
    blocks <- map fst . toList <$> bpGenBlocks Nothing
    pre (not $ null blocks)
    let blocksToVerify =
            OldestFirst $
            case blocks of
                -- impossible because of precondition (see 'pre' above)
                [] -> error "verifyValidBlocks: impossible"
                (block0:otherBlocks) ->
                    let (otherBlocks', _) = span isRight otherBlocks
                    in block0 :| otherBlocks'
    verRes <-
        lift $ satisfySlotCheck blocksToVerify $ verifyBlocksPrefix $
        blocksToVerify
    whenLeft verRes stopProperty

----------------------------------------------------------------------------
-- verifyAndApplyBlocks
----------------------------------------------------------------------------

verifyAndApplyBlocksSpec :: Spec
verifyAndApplyBlocksSpec = do
    prop applyByOneOrAllAtOnceDesc (applyByOneOrAllAtOnce applier)
  where
    applier blunds =
        let blocks = map fst blunds
        in satisfySlotCheck blocks $
           whenLeftM (verifyAndApplyBlocks True blocks) throwText
    applyByOneOrAllAtOnceDesc =
        "verifying and applying blocks one by one leads " <>
        "to the same GState as verifying and applying them all at once " <>
        "as well as applying in chunks"

----------------------------------------------------------------------------
-- applyBlocks
----------------------------------------------------------------------------

-- Commented out because tests are slow.
-- We can enable it later if we make tests much faster.

applyBlocksSpec :: Spec
applyBlocksSpec = pass
-- applyBlocksSpec = do
--     prop applyByOneOrAllAtOnceDesc (applyByOneOrAllAtOnce applier)
--   where
--     applier = applyBlocks True Nothing
--     applyByOneOrAllAtOnceDesc =
--         "applying blocks one by one leads to the same GState as " <>
--         "applying them all at once"

----------------------------------------------------------------------------
-- General functions
----------------------------------------------------------------------------

applyByOneOrAllAtOnce ::
       (OldestFirst NE (Blund SscGodTossing) -> BlockTestMode ())
    -> BlockProperty ()
applyByOneOrAllAtOnce applier = do
    bpGoToArbitraryState
    blunds <- getOldestFirst <$> bpGenBlocks Nothing
    pre (not $ null blunds)
    let blundsNE = OldestFirst (NE.fromList blunds)
    let readDB = view (lensOf @DBPureVar) >>= readIORef
    stateAfter1by1 <-
        lift $
        GS.withClonedGState $ do
            mapM_ (applier . one) (getOldestFirst blundsNE)
            readDB
    chunks <- splitIntoChunks 5 (blunds)
    stateAfterInChunks <-
        lift $
        GS.withClonedGState $ do
            mapM_ (applier . OldestFirst) chunks
            readDB
    stateAfterAllAtOnce <-
        lift $ do
            applier blundsNE
            readDB
    assert
        (stateAfter1by1 == stateAfterInChunks &&
         stateAfterInChunks == stateAfterAllAtOnce)