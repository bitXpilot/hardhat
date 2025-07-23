// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract LSRWAExpress is Ownable {
    using SafeERC20 for IERC20;
    // --- Tokens ---
    IERC20 public immutable usdc;
    IERC20 public immutable lsrwa;

    address public admin;

    // --- Constants ---
    uint256 public constant BPS_DIVISOR = 10000;
    uint256 public blocksPerYear= 2_300_000;
    uint256 public epochDuration= 40320; // in blocks
    uint256 public epochStart; // in blocks

    // --- State Variables ---
    
    uint256 public rewardAPR= 500;
    uint256 public collateralRatio= 100;

    // --- Mappings ---
    mapping(uint256 => Request) public requests;
    mapping(address => UserInfo) public users;
    mapping(address => BorrowRequest) public borrowRequests;
    mapping(address => uint256) public collateralDeposits;
    
    uint256 public borrowingUSDC;
    uint256 public rewardDebt;
    uint256 public requestCounter;

    bool public repaymentRequired;


    // --- Structs ---

    struct Request {
        address user;
        uint256 amount;
        uint256 timestamp;
        bool isWithdraw;
        bool processed;
        bool executed;
    }

    struct BorrowRequest {
        uint256 amount;   // USDC
        bool repaid;
        bool approved;
    }

    struct ApprovedRequest {
        address user;
        uint256 requestId;
        uint256 amount;
        uint256 timestamp;
        bool isWithdraw;
    }

    struct UserInfo {
        uint256 deposit;
        bool autoCompound;
        uint256 lastHarvestBlock;
    }


    // --- Events ---
    event DepositRequested(uint256 requestId, address indexed user, uint256 amount, uint256 timestamp);
    event WithdrawRequested(uint256 requestId, address indexed user, uint256 amount, uint256 timestamp);
    event DepositApproved(uint256 requestId, address indexed user, uint256 amount);
    event WithdrawApproved(uint256 requestId, address indexed user, uint256 amount);
    event PartialWithdrawalFilled(uint256 requestId, address indexed user, uint256 amount, uint256 timestamp);
    event DepositCancelled(uint256 requestId, address indexed user);
    event WithdrawExecuted(uint256 requestId, address indexed user, uint256 amount);
    event CollateralDeposited(address indexed originator, uint256 amount);
    event BorrowRequested(address indexed originator, uint256 amount);
    event BorrowExecuted(address indexed originator, uint256 seizedAmount);
    event CollateralLiquidated(uint256 seizedAmount);
    event RewardHarvested(address indexed sender, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyOriginator() {
        require(collateralDeposits[msg.sender] > 0, "Not originator");
        _;
    }

    constructor(address _usdc, address _lsrwa) Ownable(msg.sender) {
        admin = msg.sender;
        usdc = IERC20(_usdc);
        lsrwa = IERC20(_lsrwa);
    }

    function transferOwnership(address newAdmin) public override onlyAdmin {
        require(newAdmin != address(0), "Invalid address");
        admin = newAdmin;
    }

    function requestDeposit(uint256 amount) external returns (uint256 requestId) {
        require(amount > 0, "Zero amount");
        
        usdc.safeTransferFrom(            
            msg.sender,
            address(this),
            amount // uint256 _value
        );

        requestId = requestCounter++;
        requests[requestId] = Request(msg.sender, amount, block.timestamp, false, false, false);

        emit DepositRequested(requestId, msg.sender, amount, block.timestamp);
    }

    function requestWithdraw(uint256 amount) external returns (uint256 requestId) {
        require(amount > 0, "Invalid amount");
        require(users[msg.sender].deposit >= amount, "Insufficient deposit balance");

        requestId = requestCounter++;
        requests[requestId] = Request(msg.sender, amount, block.timestamp, true, false, false);
        emit WithdrawRequested(requestId, msg.sender, amount, block.timestamp);
    }

    function cancelDepositRequest(uint256 requestId) external {
        Request storage req = requests[requestId];
        require(!req.isWithdraw, "Not deposit");
        require(!req.processed, "Already processed");
        require(!req.executed, "Already cancelled");
        require(req.user == msg.sender, "Not request owner");

        usdc.safeTransfer(req.user, req.amount);
        req.processed = true;
        req.executed = true;
        
        emit DepositCancelled(requestId, req.user);
    }

    // executeWithdraw for deposit cancel after approval
   function executeWithdraw(uint256 requestId) external {
        Request storage req = requests[requestId];
        
        require(req.user == msg.sender, "Not authorized");
        require(req.isWithdraw, "Not withdraw");
        require(req.processed, "Not approved yet");
        require(!req.executed, "Already executed");
        require(req.amount > 0, "Invalid amount");
        // require(users[msg.sender].deposit >= req.amount, "Insufficient balance");

        req.executed = true;
        usdc.safeTransfer(req.user, req.amount);

        emit WithdrawExecuted(requestId, req.user, req.amount);
    }

    function setAutoCompound(bool status) external {
        users[msg.sender].autoCompound = status;
    }

    function compound() external {
        uint256 reward = calculateHarvest(msg.sender);
        require(reward > 0, "No reward");
        _compound(msg.sender);
    }

    function harvest() external {
        uint256 reward = calculateHarvest(msg.sender);
        require(reward > 0, "No reward");
        _forceHarvest(msg.sender);
    }

    function _forceHarvest(address userAddr) internal {
        uint256 reward = calculateHarvest(userAddr);
        if(reward > 0) {
            UserInfo storage u = users[userAddr];
            usdc.safeTransfer(userAddr, reward);
            rewardDebt += reward;
            u.lastHarvestBlock = block.number;
            emit RewardHarvested(userAddr, reward);
        }
    }

    function _compound(address userAddr) internal {
        uint256 reward = calculateHarvest(userAddr);
        if(reward > 0) {
            UserInfo storage u = users[userAddr];
            u.deposit += reward;
            rewardDebt += reward;
            u.lastHarvestBlock = block.number;
        }
    }

    function calculateHarvest(address userAddr) public view returns (uint256){
        UserInfo storage u = users[userAddr];
        uint256 blocks = 0;
        if(u.lastHarvestBlock > 0) {
            blocks = block.number - u.lastHarvestBlock;
        }
        uint256 reward = (u.deposit * rewardAPR * blocks) / (blocksPerYear * BPS_DIVISOR);
        return reward;
    }


    // --- Originator ---
    function depositCollateral(uint256 amount) external {
        lsrwa.safeTransferFrom(msg.sender, address(this), amount);
        collateralDeposits[msg.sender] += amount;
        
        emit CollateralDeposited(msg.sender, amount);
    }

    function requestBorrow(uint256 amount) external onlyOriginator {
        BorrowRequest storage pos = borrowRequests[msg.sender];
        require(pos.amount == 0, "Already borrowed");
        require(collateralDeposits[msg.sender] * 100 / amount >= collateralRatio, "Insufficient collateral value");

        pos.amount = amount;
        pos.repaid = false;
        pos.approved = false;

        emit BorrowRequested(msg.sender, amount);
    }

    function repayBorrow() external onlyOriginator {
        BorrowRequest storage pos = borrowRequests[msg.sender];
        require(pos.amount > 0, "Nothing to repay");
        require(pos.approved, "Not approved");
        require(!pos.repaid, "Repaid already");

        usdc.safeTransferFrom(msg.sender, address(this), pos.amount);
        borrowingUSDC -= pos.amount;
        pos.repaid = true;
        pos.amount = 0;
    }

    // --- Admin ---

    function processRequests(ApprovedRequest[] calldata arequests, address[] calldata unpaidBorrowerList) external onlyAdmin {
        // require(block.number > currentEpoch.endBlock, "Epoch not ended");

        uint256 totalActiveDeposits;
        uint256 totalWithdrawals;

        // Process approved deposit/withdraw
        for (uint256 i = 0; i < arequests.length; i++) {
            ApprovedRequest memory req = arequests[i];
            UserInfo storage u = users[req.user];
            if (req.isWithdraw) {
                Request storage wReq = requests[req.requestId];
                // if(wReq.processed) continue;
                if(users[req.user].deposit < req.amount) continue;

                uint256 reward = calculateHarvest(req.user);
                
                if(wReq.amount > req.amount) {
                    
                    uint256 remaining = wReq.amount - req.amount;
                    wReq.amount = req.amount;
                    requests[requestCounter] = Request(
                        req.user, remaining, req.timestamp, true, false, false
                    );
                    requestCounter++;
                    emit WithdrawRequested(requestCounter, req.user, remaining, req.timestamp);
                }
                
                users[req.user].deposit -= req.amount;
                
                wReq.processed = true;
                
                if(reward > 0) {
                    wReq.amount += reward;
                    rewardDebt += reward;
                    u.lastHarvestBlock = block.number;
                }
                
                totalWithdrawals += req.amount;

                emit WithdrawApproved(req.requestId, req.user, req.amount);
                
                    // repaymentRequiredEpochId = currentEpochId; // enable when needed  
                // _forceHarvest(req.user);
                
            } else {
                Request storage dReq = requests[req.requestId];
                
                // if(dReq.processed) continue;
                _compound(req.user);
                
                if(u.lastHarvestBlock == 0) u.lastHarvestBlock = block.number;

                users[req.user].deposit += req.amount;
                totalActiveDeposits += req.amount;
                dReq.processed = true;

                emit DepositApproved(req.requestId, req.user, req.amount);
            }
        }

        // Borrowing
        for (uint256 i = 0; i < unpaidBorrowerList.length; i++) {
            address borrower = unpaidBorrowerList[i];
            BorrowRequest storage bReq = borrowRequests[borrower];
            usdc.safeTransfer(borrower, bReq.amount);
            bReq.approved = true;
            borrowingUSDC += bReq.amount;
            emit BorrowExecuted(borrower, bReq.amount);
        }

        epochStart = block.number;
    }

    function adminCompound(address[] calldata activeUserList) external onlyAdmin() {
        for (uint256 i = 0; i < activeUserList.length; i++) {
            _compound(activeUserList[i]);
        }
    }

    function setRewardAPR(uint256 aprBps) external onlyAdmin {
        rewardAPR = aprBps;
    }

    function setEpochDuration(uint256 blocks) external onlyAdmin {
        epochDuration = blocks;
    }

    function setCollateralRatio(uint256 ratio) external onlyAdmin {
        collateralRatio = ratio;
    }

    function RequireRepay() external onlyAdmin {
        repaymentRequired = true;
    }

    function liquidateCollateral(address outAddress, address[] calldata unpaidBorrowerList) external onlyAdmin {
        uint256 liquidateLSRWA;
        for (uint256 i = 0; i < unpaidBorrowerList.length; i++) {
            address borrower = unpaidBorrowerList[i];
            BorrowRequest storage pos = borrowRequests[borrower];

            if(pos.repaid) continue;

            uint256 seized = collateralDeposits[borrower];
            pos.repaid = true;
            liquidateLSRWA += seized;
            pos.amount = 0;
            collateralDeposits[borrower] = 0;
        }

        // Withdraw LSRWA to outAddress and convert LSRWA to USDC off-chain and send USDC here again (it's not in contract)
        borrowingUSDC = 0;
        lsrwa.safeTransfer(outAddress, liquidateLSRWA);

        emit CollateralLiquidated(liquidateLSRWA);
    }

    function getRequests(uint kind, bool processed, uint page, uint limit, address owner, bool isAdmin)
        external
        view
        returns (Request[] memory, uint[] memory, uint)
    {
        
        Request[] memory temp = new Request[](requestCounter);
        uint[] memory tempIds = new uint[](requestCounter);

        uint j = 0;
        uint counter = 0;
        if(page == 0) {
            for (uint i = 0; i < requestCounter; i++) {
                Request storage req = requests[i];
                if(processed != req.processed || (!req.isWithdraw && req.executed) || (!isAdmin && owner != req.user)) {
                    continue;
                }
                temp[counter] = req;
                tempIds[counter] = i;
                counter++;
            }
        }
        else {
            for (uint i = 0; i < requestCounter; i++) {
                Request storage req = requests[i];
                if((isAdmin && processed != req.processed) || (!isAdmin && owner != req.user)) {
                    continue;
                }
                if(kind == 1 && req.isWithdraw) continue ;
                if(kind == 2 && !req.isWithdraw) continue ;
                temp[counter] = req;
                tempIds[counter] = i;
                counter++;
            }
        }
        Request[] memory trequests = new Request[](counter);
        uint[] memory ids = new uint[](counter);
        if(page == 0) {
            for (uint i = 0; i < counter; i++) {
                Request memory req = temp[i];
                trequests[j] = req;
                ids[j] = tempIds[i];
                j++;
            }
        }
        else {
            // pagination
            page = page - 1;
            uint end = counter > page * limit ? counter - (page * limit) : 0;
            uint start = end >= limit ? end - limit : 0;

            trequests = new Request[](end-start);

            for (uint i = end; i > start; i--) {
                Request memory req = temp[i-1];
                trequests[j] = req;
                ids[j] = tempIds[i-1];
                j++;
            }
        }

        return (trequests, ids, counter);
    }

    function getBorrowRequests(address[] calldata borrowers) onlyAdmin
        external
        view
        returns (BorrowRequest[] memory)
    {
        BorrowRequest[] memory borrows = new BorrowRequest[](borrowers.length);
        for (uint i = 0; i < borrowers.length; i++) {
            BorrowRequest storage req = borrowRequests[borrowers[i]];
            borrows[i] = req;
        }

        return borrows;
    }

    function getUnpaidBorrowList(address[] calldata borrowers, bool pending) onlyAdmin
        external
        view
        returns (BorrowRequest[] memory filters, address[] memory filters1)
    {
        uint j = 0;
        BorrowRequest[] memory temp = new BorrowRequest[](borrowers.length);
        address[] memory temp1 = new address[](borrowers.length);
        for (uint i = 0; i < borrowers.length; i++) {
            BorrowRequest storage req = borrowRequests[borrowers[i]];
            if(pending && !req.repaid && !req.approved || !pending && !req.repaid && req.approved) {
                temp[j] = req;
                temp1[j] = borrowers[i];
                j++;
            }
        }
        filters = new BorrowRequest[](j);
        filters1 = new address[](j);
        for (uint i = 0; i < j; i++) {
            filters[i] = temp[i];
            filters1[i] = temp1[i];
        }

        return (filters, filters1);
    }

    function getAutoCompoundActiveUserList(address[] calldata tusers) onlyAdmin
        external
        view
        returns (address[] memory filters)
    {
        uint j = 0;
        address[] memory temp = new address[](tusers.length);
        for (uint i = 0; i < tusers.length; i++) {
            UserInfo storage user = users[tusers[i]];
            if(user.deposit > 0 && user.autoCompound) {
                temp[j] = tusers[i];
                j++;
            }
        }
        filters = new address[](j);
        for (uint i = 0; i < j; i++) {
            filters[i] = temp[i];
        }

        return filters;
    }

    function totalDepositValue(address[] calldata tusers)
        external
        view
        returns (uint256)
    {
        uint256 total = 0;
        for (uint i = 0; i < tusers.length; i++) {
            UserInfo storage user = users[tusers[i]];
            total += user.deposit;
        }

        return total;
    }
}
