// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {L1MigrationConstants as L1} from "script/shared/L1MigrationConstants.sol";

/**
 * @notice Network-agnostic L1 upgrade actions for CSR lane migration.
 * @dev Shared logic imported by network-specific scripts and tests.
 *      The L1 receiver is shared across all L2 networks, so admin migration
 *      only needs to happen once.
 */
contract L1UpgradeActions {
    error L1UpgradeInvalidAddress();
    error L1UpgradeWrongChain(uint256 actualChainId, uint256 expectedChainId);
    error L1UpgradePostConditionFailed(string what);

    struct L1UpgradeConfig {
        address initialOwner;
        address lidoDaoAgent;
        address receiverProxy;
        address proxyAdmin;
    }

    event L1ReceiverAdminMigrated(
        address indexed receiverProxy, address indexed previousAdmin, address indexed newAdmin
    );
    event L1ProxyAdminOwnershipTransferred(
        address indexed proxyAdmin, address indexed previousOwner, address indexed newOwner
    );

    function _requireNonZeroL1(address value) private pure {
        if (value == address(0)) revert L1UpgradeInvalidAddress();
    }

    function _requireL1PostCondition(bool ok, string memory key) private pure {
        if (!ok) revert L1UpgradePostConditionFailed(key);
    }

    /// @dev Asserts the script is broadcasting to Ethereum Mainnet.
    function assertL1ChainId(uint256 expectedChainId) public view {
        if (block.chainid != expectedChainId) {
            revert L1UpgradeWrongChain(block.chainid, expectedChainId);
        }
    }

    function defaultL1Config(address initialOwner, address lidoDaoAgent)
        public
        pure
        returns (L1UpgradeConfig memory cfg)
    {
        cfg = L1UpgradeConfig({
            initialOwner: initialOwner,
            lidoDaoAgent: lidoDaoAgent,
            receiverProxy: L1.L1_LIDO_CUSTOM_RECEIVER,
            proxyAdmin: L1.L1_PROXY_ADMIN
        });
    }

    function execute(L1UpgradeConfig memory cfg) public {
        _requireNonZeroL1(cfg.initialOwner);
        _requireNonZeroL1(cfg.lidoDaoAgent);
        _requireNonZeroL1(cfg.receiverProxy);
        _requireNonZeroL1(cfg.proxyAdmin);

        IAccessControl(cfg.receiverProxy).grantRole(L1.DEFAULT_ADMIN_ROLE, cfg.lidoDaoAgent);
        IAccessControl(cfg.receiverProxy).revokeRole(L1.DEFAULT_ADMIN_ROLE, cfg.initialOwner);
        emit L1ReceiverAdminMigrated(cfg.receiverProxy, cfg.initialOwner, cfg.lidoDaoAgent);

        Ownable(cfg.proxyAdmin).transferOwnership(cfg.lidoDaoAgent);
        emit L1ProxyAdminOwnershipTransferred(cfg.proxyAdmin, cfg.initialOwner, cfg.lidoDaoAgent);

        IAccessControl recv = IAccessControl(cfg.receiverProxy);
        _requireL1PostCondition(recv.hasRole(L1.DEFAULT_ADMIN_ROLE, cfg.lidoDaoAgent), "dao agent admin grant");
        _requireL1PostCondition(!recv.hasRole(L1.DEFAULT_ADMIN_ROLE, cfg.initialOwner), "initial owner admin revoke");
        _requireL1PostCondition(Ownable(cfg.proxyAdmin).owner() == cfg.lidoDaoAgent, "proxyAdmin owner");
    }
}
