// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {GenerateAlphaEngineManageRoot} from "../../script/GenerateAlphaEngineManageRoot.s.sol";
import {AlphaEngineManageLeafHashLib} from "../../src/libraries/AlphaEngineManageLeafHashLib.sol";

contract AlphaEngineManageRootGeneratorTest is Test {
    uint256 internal constant CHAIN_ID = 421_614;
    address internal constant EXECUTION_MANAGER = 0x1111111111111111111111111111111111111111;
    address internal constant FUND_VAULT = 0x2222222222222222222222222222222222222222;
    address internal constant EXECUTOR = 0x3333333333333333333333333333333333333333;

    GenerateAlphaEngineManageRoot internal generator;
    ManageLeafHashHarness internal harness;
    string internal referenceArtifact;

    function setUp() public {
        generator = new GenerateAlphaEngineManageRoot();
        harness = new ManageLeafHashHarness();
        referenceArtifact = vm.readFile("test/vectors/alphaengine-manage-root-v1.json");
    }

    function test_referenceArtifactReproducesByteForByteAndMatchesIndependentVectors() public {
        (
            GenerateAlphaEngineManageRoot.PolicyMetadata memory metadata,
            GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory definitions
        ) = generator.referencePolicy();
        GenerateAlphaEngineManageRoot.GeneratedPolicy memory policy =
            generator.generatePolicy(metadata, definitions);

        assertEq(policy.root, vm.parseJsonBytes32(referenceArtifact, ".root"));
        assertEq(policy.leafHashes, vm.parseJsonBytes32Array(referenceArtifact, ".leafHashes"));
        assertEq(
            harness.typehash(), vm.parseJsonBytes32(referenceArtifact, ".manageLeafV1Typehash")
        );
        string memory generatedPath =
            string.concat(vm.projectRoot(), "/out/alphaengine-manage-root-v1.generated.json");
        generator.writePolicyArtifact(generatedPath, metadata, definitions);
        assertEq(keccak256(bytes(vm.readFile(generatedPath))), keccak256(bytes(referenceArtifact)));
        vm.removeFile(generatedPath);
    }

    function test_leafHashBindsEveryFieldAndUsesAbiEncoding() public view {
        AlphaEngineManageLeafHashLib.ManageLeafV1 memory leaf = _leaf();
        bytes32 baseline = harness.hashLeaf(leaf);

        bytes32 direct = keccak256(
            abi.encode(
                harness.typehash(),
                leaf.chainId,
                leaf.vaultExecutionManager,
                leaf.fundVault,
                leaf.decoder,
                leaf.decoderCodeHash,
                leaf.target,
                leaf.targetCodeHash,
                leaf.selector,
                leaf.maxNativeValue,
                keccak256(leaf.sanitizedArguments)
            )
        );
        assertEq(baseline, direct);

        leaf.chainId += 1;
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.chainId -= 1;
        leaf.vaultExecutionManager = address(0x1234);
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.vaultExecutionManager = EXECUTION_MANAGER;
        leaf.fundVault = address(0x2345);
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.fundVault = FUND_VAULT;
        leaf.decoder = address(0x3456);
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.decoder = address(0x4444);
        leaf.decoderCodeHash = keccak256("different decoder code");
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.decoderCodeHash = keccak256("decoder code");
        leaf.target = address(0x4567);
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.target = address(0x5555);
        leaf.targetCodeHash = keccak256("different target code");
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.targetCodeHash = keccak256("target code");
        leaf.selector = bytes4(keccak256("differentSelector(address)"));
        assertNotEq(harness.hashLeaf(leaf), baseline);
        leaf.selector = bytes4(keccak256("selector(address)"));
        leaf.sanitizedArguments = abi.encode(address(0x9999));
        assertNotEq(harness.hashLeaf(leaf), baseline);
    }

    function test_leafValidationFailsClosedWithTypedErrors() public {
        AlphaEngineManageLeafHashLib.ManageLeafV1 memory leaf = _leaf();

        leaf.chainId = 0;
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroChainId.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.vaultExecutionManager = address(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroVaultExecutionManager.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.fundVault = address(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroFundVault.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.decoder = address(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroDecoder.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.decoderCodeHash = bytes32(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroDecoderCodeHash.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.target = address(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroTarget.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.targetCodeHash = bytes32(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroTargetCodeHash.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.selector = bytes4(0);
        vm.expectRevert(AlphaEngineManageLeafHashLib.ZeroSelector.selector);
        harness.hashLeaf(leaf);
        leaf = _leaf();
        leaf.maxNativeValue = 1;
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineManageLeafHashLib.NativeValueNotSupported.selector, 1)
        );
        harness.hashLeaf(leaf);
    }

    function test_emptySanitizedArgumentsRemainAValidExplicitCommitment() public view {
        AlphaEngineManageLeafHashLib.ManageLeafV1 memory leaf = _leaf();
        leaf.sanitizedArguments = bytes("");

        assertEq(
            harness.hashLeaf(leaf),
            keccak256(
                abi.encode(
                    harness.typehash(),
                    leaf.chainId,
                    leaf.vaultExecutionManager,
                    leaf.fundVault,
                    leaf.decoder,
                    leaf.decoderCodeHash,
                    leaf.target,
                    leaf.targetCodeHash,
                    leaf.selector,
                    uint256(0),
                    keccak256("")
                )
            )
        );
    }

    function test_treeCardinalitiesOneTwoThreeFiveAndSixteenHaveValidProofs() public view {
        _assertPolicy(1, keccak256("one"));
        _assertPolicy(2, keccak256("two"));
        _assertPolicy(3, keccak256("three"));
        _assertPolicy(5, keccak256("five"));
        _assertPolicy(16, keccak256("sixteen"));
    }

    function test_maximumPolicyLeafCountBuildsAndVerifiesBoundaryProofs() public view {
        uint256 count = generator.MAX_POLICY_LEAVES();
        GenerateAlphaEngineManageRoot.GeneratedPolicy memory policy =
            generator.generatePolicy(_metadata(), _definitions(count, keccak256("maximum")));

        assertEq(policy.leafHashes.length, count);
        assertTrue(harness.verify(policy.proofs[0], policy.root, policy.leafHashes[0]));
        assertTrue(
            harness.verify(policy.proofs[count / 2], policy.root, policy.leafHashes[count / 2])
        );
        assertTrue(
            harness.verify(policy.proofs[count - 1], policy.root, policy.leafHashes[count - 1])
        );
    }

    function test_oddNodesAreCarriedUnchangedRatherThanDuplicated() public view {
        GenerateAlphaEngineManageRoot.GeneratedPolicy memory three =
            generator.generatePolicy(_metadata(), _definitions(3, keccak256("three")));
        assertEq(three.tree.length, 3);
        assertEq(three.tree[1].length, 2);
        assertEq(three.tree[1][1], three.tree[0][2]);
        assertEq(
            three.root,
            harness.hashPair(
                harness.hashPair(three.leafHashes[0], three.leafHashes[1]), three.leafHashes[2]
            )
        );
        assertEq(three.proofs[2].length, 1);

        GenerateAlphaEngineManageRoot.GeneratedPolicy memory five =
            generator.generatePolicy(_metadata(), _definitions(5, keccak256("five")));
        assertEq(five.tree.length, 4);
        assertEq(five.tree[1][2], five.tree[0][4]);
        assertEq(five.tree[2][1], five.tree[1][2]);
        assertEq(five.proofs[4].length, 1);
        assertTrue(harness.verify(five.proofs[4], five.root, five.leafHashes[4]));
    }

    function test_inputOrderingCannotChangeRootTreeOrProofs() public view {
        GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory forward =
            _definitions(5, keccak256("order"));
        GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory reverse =
            new GenerateAlphaEngineManageRoot.LabeledManageLeafV1[](forward.length);
        for (uint256 i; i < forward.length; ++i) {
            reverse[i] = forward[forward.length - 1 - i];
        }

        GenerateAlphaEngineManageRoot.GeneratedPolicy memory first =
            generator.generatePolicy(_metadata(), forward);
        GenerateAlphaEngineManageRoot.GeneratedPolicy memory second =
            generator.generatePolicy(_metadata(), reverse);
        assertEq(first.root, second.root);
        assertEq(first.leafHashes, second.leafHashes);
        assertEq(keccak256(abi.encode(first.tree)), keccak256(abi.encode(second.tree)));
        assertEq(keccak256(abi.encode(first.proofs)), keccak256(abi.encode(second.proofs)));
    }

    function test_duplicateEmptyOversizedAndZeroExecutorPoliciesFailTyped() public {
        GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory empty =
            new GenerateAlphaEngineManageRoot.LabeledManageLeafV1[](0);
        vm.expectRevert(GenerateAlphaEngineManageRoot.EmptyPolicy.selector);
        generator.generatePolicy(_metadata(), empty);

        GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory definitions =
            _definitions(2, keccak256("duplicate"));
        definitions[1] = definitions[0];
        bytes32 duplicateLeaf = generator.generatePolicy(
            _metadata(), _definitions(1, keccak256("duplicate"))
        ).leafHashes[0];
        vm.expectRevert(
            abi.encodeWithSelector(
                GenerateAlphaEngineManageRoot.DuplicatePolicyLeaf.selector, duplicateLeaf
            )
        );
        generator.generatePolicy(_metadata(), definitions);

        definitions = new GenerateAlphaEngineManageRoot.LabeledManageLeafV1[](
            generator.MAX_POLICY_LEAVES() + 1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GenerateAlphaEngineManageRoot.TooManyPolicyLeaves.selector,
                generator.MAX_POLICY_LEAVES() + 1,
                generator.MAX_POLICY_LEAVES()
            )
        );
        generator.generatePolicy(_metadata(), definitions);

        GenerateAlphaEngineManageRoot.PolicyMetadata memory metadata = _metadata();
        metadata.executor = address(0);
        vm.expectRevert(GenerateAlphaEngineManageRoot.ZeroExecutor.selector);
        generator.generatePolicy(metadata, _definitions(1, keccak256("executor")));

        metadata = _metadata();
        metadata.policyVersion = 0;
        vm.expectRevert(GenerateAlphaEngineManageRoot.ZeroPolicyVersion.selector);
        generator.generatePolicy(metadata, _definitions(1, keccak256("version")));

        definitions = _definitions(1, keccak256("label"));
        definitions[0].label = "";
        vm.expectRevert(
            abi.encodeWithSelector(GenerateAlphaEngineManageRoot.EmptyLeafLabel.selector, 0)
        );
        generator.generatePolicy(_metadata(), definitions);

        vm.expectRevert(GenerateAlphaEngineManageRoot.EmptyOutputPath.selector);
        generator.writePolicyArtifact("", _metadata(), _definitions(1, keccak256("path")));
    }

    function test_proofRootAndLeafMutationsFailVerification() public view {
        GenerateAlphaEngineManageRoot.GeneratedPolicy memory policy =
            generator.generatePolicy(_metadata(), _definitions(5, keccak256("mutation")));
        for (uint256 i; i < policy.leafHashes.length; ++i) {
            assertTrue(harness.verify(policy.proofs[i], policy.root, policy.leafHashes[i]));
        }

        bytes32[] memory mutatedProof = new bytes32[](policy.proofs[0].length);
        for (uint256 i; i < mutatedProof.length; ++i) {
            mutatedProof[i] = policy.proofs[0][i];
        }
        mutatedProof[0] = bytes32(uint256(mutatedProof[0]) ^ 1);
        assertFalse(harness.verify(mutatedProof, policy.root, policy.leafHashes[0]));
        assertFalse(
            harness.verify(
                policy.proofs[0], bytes32(uint256(policy.root) ^ 1), policy.leafHashes[0]
            )
        );
        assertFalse(
            harness.verify(
                policy.proofs[0], policy.root, bytes32(uint256(policy.leafHashes[0]) ^ 1)
            )
        );
    }

    function testFuzz_hashPairIsCommutative(bytes32 left, bytes32 right) public view {
        assertEq(harness.hashPair(left, right), harness.hashPair(right, left));
    }

    function testFuzz_everyGeneratedProofVerifies(uint8 rawCount, bytes32 seed) public view {
        uint256 count = bound(uint256(rawCount), 1, 16);
        _assertPolicy(count, seed);
    }

    function testFuzz_reversingDefinitionsCannotChangeRoot(uint8 rawCount, bytes32 seed)
        public
        view
    {
        uint256 count = bound(uint256(rawCount), 1, 16);
        GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory forward =
            _definitions(count, seed);
        GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory reverse =
            new GenerateAlphaEngineManageRoot.LabeledManageLeafV1[](count);
        for (uint256 i; i < count; ++i) {
            reverse[i] = forward[count - 1 - i];
        }
        assertEq(
            generator.generatePolicy(_metadata(), forward).root,
            generator.generatePolicy(_metadata(), reverse).root
        );
    }

    function _assertPolicy(uint256 count, bytes32 seed) private view {
        GenerateAlphaEngineManageRoot.GeneratedPolicy memory policy =
            generator.generatePolicy(_metadata(), _definitions(count, seed));
        assertEq(policy.leafHashes.length, count);
        assertEq(policy.tree[0].length, count);
        assertEq(policy.tree[policy.tree.length - 1].length, 1);
        assertEq(policy.root, policy.tree[policy.tree.length - 1][0]);

        for (uint256 i; i < count; ++i) {
            if (i != 0) {
                assertLt(uint256(policy.leafHashes[i - 1]), uint256(policy.leafHashes[i]));
            }
            assertTrue(harness.verify(policy.proofs[i], policy.root, policy.leafHashes[i]));
        }
    }

    function _metadata()
        private
        pure
        returns (GenerateAlphaEngineManageRoot.PolicyMetadata memory)
    {
        return GenerateAlphaEngineManageRoot.PolicyMetadata({
            chainId: CHAIN_ID,
            vaultExecutionManager: EXECUTION_MANAGER,
            fundVault: FUND_VAULT,
            executor: EXECUTOR,
            policyVersion: 1,
            referenceOnly: false
        });
    }

    function _definitions(uint256 count, bytes32 seed)
        private
        pure
        returns (GenerateAlphaEngineManageRoot.LabeledManageLeafV1[] memory definitions)
    {
        definitions = new GenerateAlphaEngineManageRoot.LabeledManageLeafV1[](count);
        for (uint256 i; i < count; ++i) {
            definitions[i] = GenerateAlphaEngineManageRoot.LabeledManageLeafV1({
                label: string.concat("action-", vm.toString(i)),
                decoder: vm.addr(1000 + i),
                decoderCodeHash: keccak256(abi.encode("decoder", seed, i)),
                target: vm.addr(2000 + i),
                targetCodeHash: keccak256(abi.encode("target", seed, i)),
                selector: bytes4(keccak256(abi.encode("selector", seed, i))),
                maxNativeValue: 0,
                sanitizedArguments: abi.encode(vm.addr(3000 + i), seed, i)
            });
        }
    }

    function _leaf() private pure returns (AlphaEngineManageLeafHashLib.ManageLeafV1 memory) {
        return AlphaEngineManageLeafHashLib.ManageLeafV1({
            chainId: CHAIN_ID,
            vaultExecutionManager: EXECUTION_MANAGER,
            fundVault: FUND_VAULT,
            decoder: address(0x4444),
            decoderCodeHash: keccak256("decoder code"),
            target: address(0x5555),
            targetCodeHash: keccak256("target code"),
            selector: bytes4(keccak256("selector(address)")),
            maxNativeValue: 0,
            sanitizedArguments: abi.encode(address(0x6666))
        });
    }
}

contract ManageLeafHashHarness {
    function typehash() external pure returns (bytes32) {
        return AlphaEngineManageLeafHashLib.manageLeafV1Typehash();
    }

    function hashLeaf(AlphaEngineManageLeafHashLib.ManageLeafV1 memory leaf)
        external
        pure
        returns (bytes32)
    {
        return AlphaEngineManageLeafHashLib.hashManageLeaf(leaf);
    }

    function hashPair(bytes32 left, bytes32 right) external pure returns (bytes32) {
        return AlphaEngineManageLeafHashLib.hashPair(left, right);
    }

    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        external
        pure
        returns (bool)
    {
        return AlphaEngineManageLeafHashLib.verifyProofCalldata(proof, root, leaf);
    }
}
