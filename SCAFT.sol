// SPDX-License-Identifier: MIT

pragma solidity ^0.5.0;

import "./EllipticCurve.sol";

/**
 * @title Hashed Timelock Contracts (HTLCs) on Ethereum.
 *
 * Protocol:
 *
 *  1) newContract(receiver, sk1, timelock) - a new buyer calls this function
 *      to create a new HTLC and gets back a 32 byte contract id.
 *  2) withdraw(contractId, sk2) - the seller/previous buyers who know sk2 
 *      can claim the ETH with this function.
 *  3) refund() - after timelock has expired and no one has claimed the funds,
 *      the creator(buyer) of the HTLC can get their ETH back with this function.
 */
contract SCAFT {

    event LogHTLCNew(
        bytes32 indexed contractId,
        address indexed sender,
        address indexed receiver,
        uint amount,
        uint256 sk1x, 
        uint256 sk1y,
        uint256 c1x,
        uint256 c1y,
        uint256 c2x,
        uint256 c2y,
        uint timelock
    );
    event LogHTLCWithdraw(bytes32 indexed contractId);
    event LogHTLCRefund(bytes32 indexed contractId);

    struct LockContract {
        address payable sender;
        address payable receiver;
        uint amount;
        uint256 sk1x; //since we are using ElGamal on Elliptic Curve as an example, sk1 is denoted as (sk1x,sk1y)
        uint256 sk1y; 
        uint256 c1x;
        uint256 c1y;
        uint256 c2x;
        uint256 c2y;
        uint timelock; // UNIX timestamp seconds
        bool withdrawn;
        bool refunded;
    }
    
    uint256 public constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 public constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    uint256 public constant AA = 0;
    uint256 public constant PP = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    modifier fundsSent() {
        require(msg.value > 0, "msg.value must be > 0");
        _;
    }
    modifier futureTimelock(uint _time) {
        // only requirement is the timelock time is after the last blocktime (now).
        // probably want something a bit further in the future then this.
        // but this is still a useful sanity check:
        require(_time > now, "timelock time must be in the future");
        _;
    }
    modifier contractExists(bytes32 _contractId) {
        require(haveContract(_contractId), "contractId does not exist");
        _;
    }
    modifier sklockMatches(bytes32 _contractId, uint256 sk2) {
        uint256 sk2x;
        uint256 sk2y;
        (sk2x, sk2y) = EllipticCurve.ecMul(sk2,GX,GY,AA,PP);                  //sk2*G(X,Y) 
        require(contracts[_contractId].sk1x == sk2x, "sk2 does not match");
        require(contracts[_contractId].sk1y == sk2y, "sk2 does not match");
        _;
    }
    modifier withdrawable(bytes32 _contractId) {
        //does not require the msg.sender to be the receiver, allowing re-selling
        require(contracts[_contractId].withdrawn == false, "withdrawable: already withdrawn");
        require(contracts[_contractId].timelock > now, "withdrawable: timelock time must be in the future");
        _;
    }
    modifier refundable(bytes32 _contractId) {
        require(contracts[_contractId].sender == msg.sender, "refundable: not sender");
        require(contracts[_contractId].refunded == false, "refundable: already refunded");
        require(contracts[_contractId].withdrawn == false, "refundable: already withdrawn");
        require(contracts[_contractId].timelock <= now, "refundable: timelock not yet passed");
        _;
    }

    mapping (bytes32 => LockContract) contracts;

    /**
     * @dev Buyer sets up HTLC using sk1, which is randomly chosen by themselves.
     *
     * @param _receiver The seller.
     * @param _sk1x x-coordninate of the random sk1 chosen by the buyer.
     * @param _sk1y y-coordninate.
     * @param _timelock UNIX time when the HTLC expires, also becomes refundable.
     * @return contractId Id of the new HTLC. This is needed for subsequent calls.
     */
    function newContract(address payable _receiver, uint256 _sk1x, uint256 _sk1y, uint256 _c1x, uint256 _c1y, uint256 _c2x,uint256 _c2y, uint _timelock)
        external
        payable
        fundsSent
        futureTimelock(_timelock)
        returns (bytes32 contractId)
    {
        contractId = keccak256(
            abi.encodePacked(
                msg.sender,
                _receiver,
                msg.value,
                _sk1x,
                _sk1y,
                _c1x,
                _c1y,
                _c2x,
                _c2y,
                _timelock
            )
        );

        // Reject if a contract already exists with the same parameters. The
        // sender must change one of these parameters to create a new distinct
        // contract.
        if (haveContract(contractId))
            revert("Contract already exists");

        contracts[contractId] = LockContract(
            msg.sender,
            _receiver,
            msg.value,
            _sk1x,
            _sk1y,
            _c1x,
            _c1y,
            _c2x,
            _c2y,
            _timelock,
            false,
            false
        );

        emit LogHTLCNew(
            contractId,
            msg.sender,
            _receiver,
            msg.value,
            _sk1x,
            _sk1y,
            _c1x,
            _c1y,
            _c2x,
            _c2y,
            _timelock
        );
    }

    /**
     * @dev Called by the receiver once they know sk2.
     * This will transfer the locked funds to their address.
     *
     * @param _contractId Id of the HTLC.
     * @param _sk2 G(X,Y)**_sk2 should equal to (sk1x,sk1y).
     * @return bool true on success
     */
    function withdraw(bytes32 _contractId, uint256 _sk2)
        external
        contractExists(_contractId)
        sklockMatches(_contractId, _sk2)
        withdrawable(_contractId)
        returns (bool)
    {
        LockContract storage c = contracts[_contractId];
        c.withdrawn = true;
        c.receiver.transfer(c.amount/2);
        msg.sender.transfer(c.amount/2);
        emit LogHTLCWithdraw(_contractId);
        return true;
    }

    /**
     * @dev Called by the sender if there was no withdraw AND the time lock has
     * expired. This will refund the contract amount.
     *
     * @param _contractId Id of HTLC to refund from.
     * @return bool true on success
     */
    function refund(bytes32 _contractId)
        external
        contractExists(_contractId)
        refundable(_contractId)
        returns (bool)
    {
        LockContract storage c = contracts[_contractId];
        c.refunded = true;
        c.sender.transfer(c.amount);
        emit LogHTLCRefund(_contractId);
        return true;
    }

    /**
     * @dev Get contract details.
     * @param _contractId HTLC contract id
     * return All parameters in struct LockContract for _contractId HTLC
     */
    function getContract(bytes32 _contractId) 
    public 
    view 
    returns (
        address sender,
        address receiver,
        uint amount,
        uint256 sk1x,
        uint256 sk1y,
        uint timelock,
        bool withdrawn,
        bool refunded)
    {
        if (haveContract(_contractId) == false)
            return (address(0), address(0), 0, 0, 0, 0, false, false);
        LockContract storage c = contracts[_contractId];
        return (
            c.sender,
            c.receiver,
            c.amount,
            c.sk1x,
            c.sk1y,
            c.timelock,
            c.withdrawn,
            c.refunded
        );
    }

    /**
     * @dev Is there a contract with id _contractId.
     * @param _contractId Id into contracts mapping.
     */
    function haveContract(bytes32 _contractId)
        internal
        view
        returns (bool exists)
    {
        exists = (contracts[_contractId].sender != address(0));
    }

}