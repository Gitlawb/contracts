// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GitlawbTestToken
/// @notice TESTNET-ONLY mock $GITLAWB token for Base Sepolia e2e testing.
///
/// Public `mint(to, amount)` — anyone can mint. Do NOT deploy to mainnet.
/// For mainnet use the real $GITLAWB at 0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3.
contract GitlawbTestToken {
    string public constant name = "Gitlawb Test Token";
    string public constant symbol = "tGITLAWB";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// Anyone can mint — testnet only.
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
