// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@aave/periphery-v3/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import "@kaia/contracts/system_contracts/consensus/PublicDelegation/IPublicDelegation.sol";

/**
 * @title KaiaPayVault
 * @dev 예치, 출금, Aave 통합을 관리하는 Vault 컨트랙트
 * @dev UUPS 프록시 패턴을 사용하여 업그레이드 가능한 컨트랙트
 */
contract KaiaPayVault is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    receive() external payable {}
    
    using SafeERC20 for IERC20;

    // 이벤트 정의
    event TokenDeposited(address indexed from, address indexed to, address indexed token, uint256 amount);
    event TokenWithdrawn(address indexed from, address indexed to, address indexed token, uint256 amount);
    event TokenTransferred(address indexed from, address indexed to, address indexed token, uint256 amount, uint256 deadline, address owner);
    event EmergencyWithdraw(address indexed owner, address indexed token, uint256 amount);
    event AaveSupplied(address indexed token, uint256 amount);
    event AaveWithdrawn(address indexed token, uint256 amount);
    event AaveBorrowed(address indexed token, uint256 amount);
    event AaveRepaid(address indexed token, uint256 amount);
    event TransferDeadlineSet(address indexed from, address indexed to, address indexed token, uint256 deadline);
    event AaveBorrowFailed(address indexed token, uint256 amount, string reason);
    event ContractUpgraded(uint256 indexed oldVersion, uint256 indexed newVersion, address indexed newImplementation);
    event TokenConfigUpdated(address indexed token, address pool, bool supplyEnabled, bool borrowEnabled);
    event TokenAavePaused(address indexed token);
    event TokenAaveUnpaused(address indexed token);
    event InterestAccumulated(address indexed token, uint256 interestAmount, uint256 platformFee, uint256 userInterest);
    event InterestClaimed(address indexed user, address indexed token, uint256 amount);
    event PlatformFeeCollected(address indexed token, uint256 amount, address indexed wallet);
    event PlatformFeeConfigUpdated(address indexed wallet, uint256 percentage, uint256 minimumClaim);
    event PlatformFeeWalletChangeInitiated(address indexed currentWallet, address indexed newWallet, uint256 changeTime);
    event PlatformFeeWalletChanged(address indexed oldWallet, address indexed newWallet);
    event GovernanceCouncilMemberAdded(address indexed member);
    event GovernanceCouncilMemberRemoved(address indexed member);
    event CurrentGovernanceCouncilMemberSet(address indexed member);
    event DelegationStaked(address indexed member, uint256 amount);
    event DelegationWithdrawn(address indexed member, uint256 amount);
    event DelegationClaimed(address indexed member, uint256 amount);
    
    struct Pot {
        uint256 balance;        // 토큰 잔액
        address owner;          // 소유자 주소
        uint256 deadline;       // 전송 만료 시간 (0이면 제한 없음)
    }
    
    // 상태 변수들
    mapping(address => mapping(address => Pot)) private pots; // 사용자 => 토큰 => 포트

    mapping(address => bool) public supportedTokens;                    // 지원되는 토큰 목록
    mapping(address => uint256) public totalSuppliedToAave;            // 토큰별 Aave에 공급된 총량
    mapping(address => uint256) public totalUserBalance;               // 토큰별 전체 사용자 잔액
    
    // 표준 리베이스 메커니즘을 사용한 이자 추적 시스템
    mapping(address => uint256) public globalInterestIndex;            // 토큰별 누적 이자 지수 (정밀도를 위해 1e27로 스케일링)
    mapping(address => mapping(address => uint256)) public userLastInterestIndex;    // 사용자별 토큰별 마지막 청구 지수
    mapping(address => mapping(address => uint256)) public userAccumulatedInterest;   // 사용자별 토큰별 누적 이자
    mapping(address => uint256) public totalInterestEarned;            // 토큰별 Aave에서 획득한 총 이자
    mapping(address => uint256) public platformFeesCollected;         // 토큰별 수집된 총 플랫폼 수수료
    mapping(address => uint256) public lastInterestUpdateTime;        // 토큰별 마지막 이자 업데이트 시간
    
    // 플랫폼 수수료 설정
    address public platformFeeWallet;                               // 플랫폼 수수료 지갑 주소
    address public pendingPlatformFeeWallet;                        // 타임락을 위한 대기 중인 지갑 주소
    uint256 public platformFeeWalletChangeTime;                     // 지갑 변경이 시작된 타임스탬프
    uint256 public constant WALLET_CHANGE_DELAY = 2 days;           // 지갑 변경 지연 시간
    uint256 public platformFeePercentage = 1500;                    // 플랫폼 수수료 비율 15% (기본점: 10000 = 100%)
    uint256 public minimumInterestClaim = 1e6;                      // 최소 이자 청구 금액 (0.001 토큰)
    uint256 public constant INTEREST_PRECISION = 1e27;              // 이자 계산을 위한 고정밀도
    uint256 public constant MAX_PLATFORM_FEE_BALANCE = 1e24;        // 토큰별 최대 누적 수수료 (18자리 소수점 기준 1M 토큰)
    mapping(address => uint256) public platformFeeBalance;           // 토큰별 누적된 플랫폼 수수료
    
    // 토큰별 유연한 Aave 설정
    struct TokenConfig {
        IPool pool;                    // 사용할 Aave 풀 주소
        address aToken;                // aToken 주소 (첫 공급 시 설정됨)
        bool supplyEnabled;            // Aave 공급 활성화 여부
        bool borrowEnabled;            // 대출 트리거 활성화 여부
        address borrowToken;           // 대출할 토큰 주소
        address borrowGateway;         // 대출에 사용할 게이트웨이 주소
        address debtToken;             // 위임을 위한 가변 부채 토큰 주소
        uint256 maxSupply;             // 최대 공급 금액
        uint256 maxBorrow;             // 최대 대출 금액
        uint8 decimals;                // 토큰 소수점 자릿수 (USDT: 6, KAIA: 18 등)
    }
    
    mapping(address => TokenConfig) public tokenConfigs;              // 토큰별 설정 정보
    uint256 public targetLTV;                                         // 목표 LTV (Loan-to-Value)
    uint256 public constant MAX_LTV = 8000;                           // 최대 80% LTV
    
    // 업그레이드를 위한 버전 추적
    uint256 public version;
    
    // 거버넌스 카운실 위임 관리
    address payable[] public governanceCouncilMembers;              // PublicDelegation 컨트랙트 주소 배열
    address payable public currentGovernanceCouncilMemberAddress;   // 현재 활성화된 거버넌스 카운실 멤버 주소
    
    /**
     * @dev 상속 체인에서 스토리지를 이동시키지 않고 향후 버전에서 새로운 변수를 추가할 수 있도록
     * 예약된 빈 공간입니다.
     * 자세한 내용: https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[40] private __gap;
    
    // 수정자 (Modifiers)
    modifier onlySupportedToken(address token) {
        require(supportedTokens[token], "Token not supported");
        _;
    }
    
    modifier onlyConfiguredToken(address token) {
        require(address(tokenConfigs[token].pool) != address(0), "Token not configured");
        _;
    }
    
    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than 0");
        _;
    }
    
    modifier validAddress(address addr) {
        require(addr != address(0), "Invalid address");
        _;
    }
    
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev 컨트랙트 초기화 (업그레이드 가능한 컨트랙트의 생성자 대체)
     * @param _owner 컨트랙트 소유자
     */
    function initialize(address _owner) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        // 기본값 초기화
        targetLTV = 5000; // 50% LTV (기본점: 10000 = 100%)
        version = 1; // 초기 버전
        
        // 플랫폼 수수료 지갑 설정 (초기에는 소유자로 설정, 나중에 변경 가능)
        platformFeeWallet = _owner;
        
        // 유연한 Aave 통합을 위한 기본 USDT 설정 구성
        _setupTokenConfig(
            0xd077A400968890Eacc75cdc901F0356c943e4fDb, // USDT 토큰 주소
            IPool(0xCf1af042f2A071DF60a64ed4BdC9c7deE40780Be), // USDT 풀 주소
            true,  // 공급 활성화
            true,  // 대출 활성화
            0x19Aac5f612f524B754CA7e7c41cbFa2E981A4432, // WKAIA 대출 토큰
            address(IWrappedTokenGatewayV3(0x7aAd7A95fCf14B826AC96176590C8e7aad19bbd4)), // WKAIA 게이트웨이
            0xaDa27a9E7fC5E5256Adf1225BC94e30973fAC274, // 가변 부채 토큰
            6  // USDT 소수점 자릿수
        );
    }
    
    /**
     * @dev 외부에서 토큰을 vault로 입금하는 함수
     * @param to 입금할 KaiaPay 내 지갑 주소
     * @param token 입금할 토큰 주소
     * @param amount 입금할 토큰 수량
     */
    function depositToken(address to, address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        onlySupportedToken(token)
        validAmount(amount)
        validAddress(to)
        validAddress(token)
    {
        // 입금 전 사용자 이자 업데이트
        _updateUserInterest(to, token);
        
        // pots[to][token]이 존재하지 않으면 새로 생성
        if (pots[to][token].owner == address(0)) {
            pots[to][token].owner = to;
            pots[to][token].deadline = 0;
            // 이 토큰에 대한 사용자의 이자 지수 초기화 (이자 업데이트 후)
            userLastInterestIndex[to][token] = globalInterestIndex[token];
        } else {
            // 임시 주소가 있으면 실패
            require(pots[to][token].owner == to, "Temporary pot cannot be deposited");
        }

        // 사용자로부터 토큰을 컨트랙트로 전송
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // 사용자의 내부 잔액 증가
        pots[to][token].balance += amount;
        
        // 전체 사용자 잔액 증가
        totalUserBalance[token] += amount;
        
        // Aave 공급이 활성화된 토큰이면 자동으로 Aave에 공급
        TokenConfig storage config = tokenConfigs[token];
        if (config.supplyEnabled && address(config.pool) != address(0)) {
            _supplyToAave(token, amount);
            
            // 공급 후 빌릴 수 있는 만큼 특정 토큰을 자동으로 대출
            if (config.borrowEnabled && config.borrowToken != address(0) && config.borrowGateway != address(0)) {
                uint256 borrowedAmount = _autoBorrowFromAave(token);
                if (borrowedAmount > 0) {
                    _stakeToGovernanceCouncil(borrowedAmount);
                }
            }
        }
        
        emit TokenDeposited(msg.sender, to, token, amount);
    }
    
    /**
     * @dev vault에서 외부로 토큰을 출금하는 함수 (필요시 Aave에서 출금)
     * @param to 출금할 kaia 주소
     * @param token 출금할 토큰 주소
     * @param amount 출금할 토큰 수량
     */
    function withdrawToken(address to, address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        onlySupportedToken(token)
        validAmount(amount)
        validAddress(to)
        validAddress(token)
    {
        // 임시 주소라면 실패 
        require(pots[msg.sender][token].owner == msg.sender, "Temporary pot cannot be withdrawn");

        require(pots[msg.sender][token].balance >= amount, "Insufficient balance");
        
        // 출금 전 사용자 이자 업데이트
        _updateUserInterest(msg.sender, token);
        
        // 컨트랙트 내 토큰 잔액 확인
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        
        // 필요한 만큼 Aave에서 출금
        if (contractBalance < amount) {
            TokenConfig storage config = tokenConfigs[token];
            require(address(config.pool) != address(0), "Token not configured for Aave");
            require(config.supplyEnabled, "Insufficient contract balance and Aave supply disabled");
            uint256 withdrawFromAave = amount - contractBalance;
            _withdrawFromAave(token, withdrawFromAave);
        }
        
        // 사용자의 내부 잔액 감소 (외부 호출 전)
        pots[msg.sender][token].balance -= amount;
        
        // 전체 사용자 잔액 감소
        totalUserBalance[token] -= amount;
        
        // 컨트랙트에서 사용자로 토큰 전송
        IERC20(token).safeTransfer(to, amount);
        
        emit TokenWithdrawn(msg.sender, to, token, amount);
    }
   
    /**
     * @dev 토큰 전송 로직
     * @param from 송신자 주소
     * @param to 받는 사용자 주소
     * @param token 전송할 토큰 주소
     * @param amount 전송할 토큰 수량
     * @param deadline 전송 deadline (0이면 제한 없음)
     * @param owner 소유자 주소
     */
    function transferToken(address from, address to, address token, uint256 amount, uint256 deadline, address owner) external 
        nonReentrant
        whenNotPaused 
        onlySupportedToken(token)
        validAmount(amount)
        validAddress(from)
        validAddress(to)
        validAddress(owner)
        validAddress(token) {
            // 두가지 케이스
            // 1. temporary pot 에서의 전송
            //  1.1 owner로 명시된 지갑이 전송
            //  1.2 temporary pot의 지갑이 전송
            // 2. user pot 에서의 전송
            //  2.1 user pot의 지갑이 전송
            require(from != to, "Cannot transfer to self");
            require(pots[from][token].balance >= amount, "Insufficient balance");
            // Enhanced permission check
            require(
                from == msg.sender || 
                (pots[from][token].owner == msg.sender && pots[from][token].owner != from),
                "Not permitted to transfer"
            );
            
            // Update interest for both users BEFORE balance changes
            _updateUserInterest(from, token);
            _updateUserInterest(to, token);

            if(to != owner) { // temporary pot 으로의 전송일 경우,
                // 해당 pot이 이미 존재하지 않아야함
                require(pots[to][token].owner == address(0), "Temporary pot already exists with this address");
                pots[to][token].owner = owner;
                pots[to][token].deadline = deadline;
                pots[to][token].balance = amount;
                // 임시 포트의 이자 지수 초기화
                userLastInterestIndex[to][token] = globalInterestIndex[token];
            } else { // user pot 으로의 전송일 경우,
                if (pots[from][token].deadline != 0) {
                    // temporary pot은 owner 가 아니라면, deadline 이 지나지 않아야 전송 가능
                    require(msg.sender == pots[from][token].owner || block.timestamp <= pots[from][token].deadline, "Transfer deadline expired");
                }
                if(pots[to][token].owner == address(0)) {
                    // 아직 사용자 포트가 생성되지 않았다면 생성
                    pots[to][token].owner = to;
                    pots[to][token].deadline = 0;
                    pots[to][token].balance = amount;
                    // 새 사용자의 이자 지수 초기화
                    userLastInterestIndex[to][token] = globalInterestIndex[token];
                } else {
                    // 해당 pot이 temporary pot이 아니어야함
                    require(pots[to][token].owner == to, "Temporary pot already exists with this address");

                    // 이미 사용자 포트가 있으니 잔액 증가
                    pots[to][token].balance += amount;
                }
            }

            pots[from][token].balance -= amount;
            
            // 전체 사용자 잔액은 변경되지 않음 (내부 전송이므로)
            // totalUserBalance[token]은 동일하게 유지
            
            emit TokenTransferred(from, to, token, amount, deadline, owner);
    }
    
    /**
     * @dev 사용자의 포트 조회
     * @param user 사용자 주소
     * @param token 토큰 주소
     * @return 잔액, 만료일, 소유자
     */
    function getPot(address user, address token) external view returns (uint256, uint256, address) {
        return (pots[user][token].balance, pots[user][token].deadline, pots[user][token].owner);
    }
 
    /**
     * @dev 지원되는 토큰 추가 (관리자만)
     * @param token 토큰 주소
     */
    function addSupportedToken(address token) external onlyOwner validAddress(token) {
        supportedTokens[token] = true;
    }
    
    /**
     * @dev 지원되는 토큰 제거 (관리자만)
     * @param token 토큰 주소
     */
    function removeSupportedToken(address token) external onlyOwner validAddress(token) {
        supportedTokens[token] = false;
    }
    
    /**
     * @dev 컨트랙트 일시정지 (관리자만)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev 컨트랙트 재개 (관리자만)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev 비상 출금 (관리자만)
     * @param token 토큰 주소
     * @param amount 출금할 수량
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner validAmount(amount) {
        // 컨트랙트에서 소유자로 토큰 전송
        IERC20(token).safeTransfer(owner(), amount);
        
        emit EmergencyWithdraw(owner(), token, amount);
    }
    
    /**
     * @dev 특정 토큰의 Aave 공급 일시정지 (관리자만)
     * @param token 토큰 주소
     */
    function pauseTokenAave(address token) external onlyOwner onlyConfiguredToken(token) {
        TokenConfig storage config = tokenConfigs[token];
        config.supplyEnabled = false;
        config.borrowEnabled = false;
        emit TokenAavePaused(token);
    }
    
    /**
     * @dev 특정 토큰의 Aave 공급 재개 (관리자만)
     * @param token 토큰 주소
     */
    function unpauseTokenAave(address token) external onlyOwner onlyConfiguredToken(token) {
        TokenConfig storage config = tokenConfigs[token];
        config.supplyEnabled = true;
        config.borrowEnabled = true;
        emit TokenAaveUnpaused(token);
    }
    
    /**
     * @dev 컨트랙트에 보유된 특정 토큰의 총량 조회
     * @param token 토큰 주소
     * @return 총 보유량
     */
    function getContractBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
    
    /**
     * @dev 토큰별 Aave 설정 구성 (관리자만)
     * @param token 토큰 주소
     * @param pool Aave 풀 주소
     * @param supplyEnabled 공급 활성화 여부
     * @param borrowEnabled 대출 활성화 여부
     * @param borrowToken 대출할 토큰 주소
     * @param borrowGateway 대출 게이트웨이 주소
     * @param debtToken 가변 부채 토큰 주소
     * @param decimals 토큰 소수점 자릿수
     */
    function setTokenConfig(
        address token,
        IPool pool,
        bool supplyEnabled,
        bool borrowEnabled,
        address borrowToken,
        address borrowGateway,
        address debtToken,
        uint8 decimals
    ) external onlyOwner validAddress(token) validAddress(address(pool)) {
        _setupTokenConfig(token, pool, supplyEnabled, borrowEnabled, borrowToken, borrowGateway, debtToken, decimals);
        emit TokenConfigUpdated(token, address(pool), supplyEnabled, borrowEnabled);
    }
    
    /**
     * @dev 토큰별 Aave 공급 활성화/비활성화 (관리자만) - 하위 호환성
     * @param token 토큰 주소
     * @param enabled 활성화 여부
     */
    function setAaveSupplyEnabled(address token, bool enabled) external onlyOwner validAddress(token) {
        TokenConfig storage config = tokenConfigs[token];
        config.supplyEnabled = enabled;
    }
    
    /**
     * @dev 토큰별 Aave 대출 활성화/비활성화 (관리자만)
     * @param token 토큰 주소
     * @param enabled 활성화 여부
     */
    function setAaveBorrowEnabled(address token, bool enabled) external onlyOwner validAddress(token) {
        TokenConfig storage config = tokenConfigs[token];
        config.borrowEnabled = enabled;
    }
    
    /**
     * @dev 토큰별 Aave 풀 주소 업데이트 (관리자만)
     * @param token 토큰 주소
     * @param newPool 새로운 Aave 풀 주소
     */
    function setTokenPool(address token, IPool newPool) external onlyOwner validAddress(token) validAddress(address(newPool)) {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        config.pool = newPool;
        config.aToken = address(0); // 풀별로 다르므로 aToken 재설정
        emit TokenConfigUpdated(token, address(newPool), config.supplyEnabled, config.borrowEnabled);
    }
    
    /**
     * @dev 토큰별 대출 게이트웨이 업데이트 (관리자만)
     * @param token 토큰 주소
     * @param newGateway 새로운 대출 게이트웨이 주소
     */
    function setTokenBorrowGateway(address token, address newGateway) external onlyOwner validAddress(token) validAddress(newGateway) {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        config.borrowGateway = newGateway;
        emit TokenConfigUpdated(token, address(config.pool), config.supplyEnabled, config.borrowEnabled);
    }
    
    /**
     * @dev 토큰별 대출 토큰 업데이트 (관리자만)
     * @param token 토큰 주소
     * @param newBorrowToken 새로운 대출 토큰 주소
     */
    function setTokenBorrowToken(address token, address newBorrowToken) external onlyOwner validAddress(token) validAddress(newBorrowToken) {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        config.borrowToken = newBorrowToken;
        emit TokenConfigUpdated(token, address(config.pool), config.supplyEnabled, config.borrowEnabled);
    }
    
    /**
     * @dev 토큰별 debt token 업데이트 (관리자만)
     * @param token 토큰 주소
     * @param newDebtToken 새로운 debt token 주소
     */
    function setTokenDebtToken(address token, address newDebtToken) external onlyOwner validAddress(token) validAddress(newDebtToken) {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        config.debtToken = newDebtToken;
        emit TokenConfigUpdated(token, address(config.pool), config.supplyEnabled, config.borrowEnabled);
    }
    
    /**
     * @dev 토큰별 소수점 자릿수 설정 (관리자만)
     * @param token 토큰 주소
     * @param decimals 소수점 자릿수
     */
    function setTokenDecimals(address token, uint8 decimals) external onlyOwner validAddress(token) {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        require(decimals <= 18, "Decimals cannot exceed 18");
        config.decimals = decimals;
        emit TokenConfigUpdated(token, address(config.pool), config.supplyEnabled, config.borrowEnabled);
    }
    
    /**
     * @dev 목표 LTV 설정 (관리자만)
     * @param _targetLTV 목표 LTV (basis points)
     */
    function setTargetLTV(uint256 _targetLTV) external onlyOwner {
        require(_targetLTV <= MAX_LTV, "LTV too high");
        targetLTV = _targetLTV;
    }
    
    /**
     * @dev Aave에서 토큰 대출 (관리자만)
     * @param token 담보 토큰 주소
     * @param amount 대출할 수량
     */
    function borrowFromAave(address token, uint256 amount) external onlyOwner validAmount(amount) onlyConfiguredToken(token) {
        TokenConfig storage config = tokenConfigs[token];
        require(config.borrowEnabled, "Borrow not enabled for this token");
        require(config.borrowToken != address(0), "Borrow token not set");
        
        // 대출 실행 (가변 이율: 2)
        _executeBorrow(token, config, amount);
        
        emit AaveBorrowed(config.borrowToken, amount);
    }
    
    /**
     * @dev Aave 대출 상환 (관리자만)
     * @param token 담보 토큰 주소
     * @param amount 상환할 수량
     */
    function repayToAave(address token, uint256 amount) external onlyOwner validAmount(amount) onlyConfiguredToken(token) {
        TokenConfig storage config = tokenConfigs[token];
        require(config.borrowEnabled, "Borrow not enabled for this token");
        require(config.borrowToken != address(0), "Borrow token not set");
        
        // 토큰 승인
        IERC20(config.borrowToken).approve(config.borrowGateway, amount);
        
        // 대출 상환 (가변 이율: 2)
        _executeRepay(token, config, amount);
        
        emit AaveRepaid(config.borrowToken, amount);
    }
    
    /**
     * @dev 계정의 Aave 데이터 조회
     * @param token 토큰 주소
     * @return totalCollateralBase 담보 총액
     * @return totalDebtBase 부채 총액
     * @return availableBorrowsBase 대출 가능 금액
     * @return currentLiquidationThreshold 청산 임계값
     * @return ltv 현재 LTV
     * @return healthFactor 건강도 지수
     */
    function getAaveAccountData(address token) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) {
        TokenConfig memory config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        return config.pool.getUserAccountData(address(this));
    }
    
    /**
     * @dev 토큰의 aToken 주소 조회
     * @param token 토큰 주소
     * @return aToken 주소
     */
    function getATokenAddress(address token) external view returns (address) {
        TokenConfig memory config = tokenConfigs[token];
        require(address(config.pool) != address(0), "Token not configured");
        
        if (config.aToken != address(0)) {
            return config.aToken;
        }
        
        // aToken이 아직 설정되지 않았다면 풀에서 가져오기
        DataTypes.ReserveData memory reserveData = config.pool.getReserveData(token);
        return reserveData.aTokenAddress;
    }
    
    /**
     * @dev 토큰 설정 정보 조회
     * @param token 토큰 주소
     * @return pool Aave 풀 주소
     * @return aToken aToken 주소
     * @return supplyEnabled 공급 활성화 여부
     * @return borrowEnabled 대출 활성화 여부
     * @return borrowToken 대출할 토큰 주소
     * @return borrowGateway 대출 게이트웨이 주소
     * @return debtToken Variable debt token 주소
     * @return decimals 토큰 소수점 자릿수
     */
    function getTokenConfig(address token) external view returns (
        address pool,
        address aToken,
        bool supplyEnabled,
        bool borrowEnabled,
        address borrowToken,
        address borrowGateway,
        address debtToken,
        uint8 decimals
    ) {
        TokenConfig memory config = tokenConfigs[token];
        return (
            address(config.pool),
            config.aToken,
            config.supplyEnabled,
            config.borrowEnabled,
            config.borrowToken,
            config.borrowGateway,
            config.debtToken,
            config.decimals
        );
    }
    
    /**
     * @dev 전체 vault 상태 조회
     * @return contractVersion 현재 컨트랙트 버전
     * @return currentTargetLTV 목표 LTV 설정
     * @return maxLTV 최대 LTV 제한
     * @return isPaused 전체 컨트랙트 일시정지 상태
     * @return owner 컨트랙트 소유자
     */
    function getVaultStatus() external view returns (
        uint256 contractVersion,
        uint256 currentTargetLTV,
        uint256 maxLTV,
        bool isPaused,
        address owner
    ) {
        return (
            version,
            targetLTV,
            MAX_LTV,
            paused(),
            owner
        );
    }
    
    /**
     * @dev User claims their accrued interest for a specific token
     * @param token Token address to claim interest for
     */
    function claimInterest(address token) external nonReentrant whenNotPaused onlySupportedToken(token) {
        // Update interest first
        _updateUserInterest(msg.sender, token);
        
        // Get claimable interest
        uint256 totalClaimable = userAccumulatedInterest[msg.sender][token];
        
        // Get token-specific minimum claim amount with safe decimal handling
        uint8 decimals = tokenConfigs[token].decimals;
        require(decimals > 0, "Token decimals not set");
        
        uint256 tokenMinimumClaim;
        if (decimals >= 6) {
            // 6자리 이상 소수점을 가진 토큰은 스케일 업
            tokenMinimumClaim = minimumInterestClaim * (10 ** (decimals - 6));
        } else {
            // 6자리 미만 소수점을 가진 토큰은 스케일 다운
            // decimals > 0 체크가 위에 있으므로 안전함
            tokenMinimumClaim = minimumInterestClaim / (10 ** (6 - decimals));
        }
        
        require(totalClaimable >= tokenMinimumClaim, "Interest too small to claim");
        require(totalClaimable > 0, "No interest to claim");
        
        // 누적된 이자 초기화
        userAccumulatedInterest[msg.sender][token] = 0;
        
        // 사용자에게 이자 전송
        IERC20(token).safeTransfer(msg.sender, totalClaimable);
        
        emit InterestClaimed(msg.sender, token, totalClaimable);
    }
    
    /**
     * @dev 특정 토큰에 대한 사용자의 대기 중인 이자 계산
     * @param user 사용자 주소
     * @param token 토큰 주소
     * @return pendingInterest 누적에 추가될 대기 중인 이자 금액
     */
    function calculateUserInterest(address user, address token) public view returns (uint256 pendingInterest) {
        uint256 userBalance = pots[user][token].balance;
        if (userBalance == 0) return 0;
        
        uint256 currentIndex = globalInterestIndex[token];
        uint256 userLastIndex = userLastInterestIndex[user][token];
        
        // 고정밀도로 이자 계산
        if (currentIndex > userLastIndex) {
            pendingInterest = (userBalance * (currentIndex - userLastIndex)) / INTEREST_PRECISION;
        }
    }
    
    /**
     * @dev 특정 토큰에 대한 사용자의 총 청구 가능한 이자 조회
     * @param user 사용자 주소
     * @param token 토큰 주소
     * @return totalClaimable 사용자가 청구할 수 있는 총 이자
     */
    function getTotalClaimableInterest(address user, address token) external view returns (uint256 totalClaimable) {
        uint256 pendingInterest = calculateUserInterest(user, token);
        uint256 accumulatedInterest = userAccumulatedInterest[user][token];
        totalClaimable = pendingInterest + accumulatedInterest;
    }
    
    /**
     * @dev 특정 토큰의 상세 상태 조회
     * @param token 토큰 주소
     * @return isSupported 지원되는 토큰인지 여부
     * @return isConfigured Aave 설정이 되어있는지 여부
     * @return contractBalance 컨트랙트에 보유된 토큰 수량
     * @return aaveSupplied Aave에 공급된 토큰 수량
     * @return userBalanceTotal 모든 사용자의 총 잔액
     */
    function getTokenStatus(address token) external view returns (
        bool isSupported,
        bool isConfigured,
        uint256 contractBalance,
        uint256 aaveSupplied,
        uint256 userBalanceTotal
    ) {
        isSupported = supportedTokens[token];
        isConfigured = address(tokenConfigs[token].pool) != address(0);
        contractBalance = IERC20(token).balanceOf(address(this));
        aaveSupplied = totalSuppliedToAave[token];
        userBalanceTotal = totalUserBalance[token]; // Now returns real tracked value
    }
    
    /**
     * @dev 특정 토큰의 전체 사용자 잔액 조회
     * @param token 토큰 주소
     * @return 전체 사용자 잔액
     */
    function getTotalUserBalance(address token) external view returns (uint256) {
        return totalUserBalance[token];
    }
    
    /**
     * @dev Initiate platform fee wallet change with timelock (owner only)
     * @param _newWallet New platform fee wallet address
     */
    function initiatePlatformFeeWalletChange(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Invalid fee wallet address");
        require(_newWallet != platformFeeWallet, "Same as current wallet");
        
        pendingPlatformFeeWallet = _newWallet;
        platformFeeWalletChangeTime = block.timestamp;
        
        emit PlatformFeeWalletChangeInitiated(platformFeeWallet, _newWallet, block.timestamp + WALLET_CHANGE_DELAY);
    }
    
    /**
     * @dev Complete platform fee wallet change after timelock (owner only)
     */
    function completePlatformFeeWalletChange() external onlyOwner {
        require(pendingPlatformFeeWallet != address(0), "No pending wallet change");
        require(block.timestamp >= platformFeeWalletChangeTime + WALLET_CHANGE_DELAY, "Timelock not expired");
        
        address oldWallet = platformFeeWallet;
        platformFeeWallet = pendingPlatformFeeWallet;
        pendingPlatformFeeWallet = address(0);
        platformFeeWalletChangeTime = 0;
        
        emit PlatformFeeWalletChanged(oldWallet, platformFeeWallet);
    }
    
    /**
     * @dev Cancel pending platform fee wallet change (owner only)
     */
    function cancelPlatformFeeWalletChange() external onlyOwner {
        require(pendingPlatformFeeWallet != address(0), "No pending wallet change");
        
        pendingPlatformFeeWallet = address(0);
        platformFeeWalletChangeTime = 0;
    }
    
    /**
     * @dev Set platform fee percentage and minimum claim (owner only)
     * @param _platformFeePercentage New platform fee percentage (basis points)
     * @param _minimumInterestClaim New minimum interest claim amount
     */
    function setPlatformFeeConfig(
        uint256 _platformFeePercentage,
        uint256 _minimumInterestClaim
    ) external onlyOwner {
        require(_platformFeePercentage <= 5000, "Platform fee cannot exceed 50%");
        require(_minimumInterestClaim > 0, "Minimum claim must be greater than 0");
        
        platformFeePercentage = _platformFeePercentage;
        minimumInterestClaim = _minimumInterestClaim;
        
        emit PlatformFeeConfigUpdated(platformFeeWallet, _platformFeePercentage, _minimumInterestClaim);
    }
    
    /**
     * @dev Withdraw accumulated platform fees (platform fee wallet only)
     * @param token Token address to withdraw fees for
     */
    function withdrawPlatformFees(address token) external nonReentrant {
        require(msg.sender == platformFeeWallet, "Only platform fee wallet can withdraw");
        
        uint256 fees = platformFeeBalance[token];
        require(fees > 0, "No fees to withdraw");
        
        platformFeeBalance[token] = 0;
        IERC20(token).safeTransfer(platformFeeWallet, fees);
        
        emit PlatformFeeCollected(token, fees, platformFeeWallet);
    }
    
    /**
     * @dev Emergency withdrawal of accumulated platform fees (owner only)
     * @param token Token address to withdraw fees for
     * @param recipient Address to receive the fees
     */
    function emergencyWithdrawPlatformFees(address token, address recipient) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        
        // 수수료가 30일 이상 막혀있거나 누적된 수수료가 최대 한도를 초과한 경우에만
        // 비상 출금 허용
        uint256 fees = platformFeeBalance[token];
        require(
            fees > MAX_PLATFORM_FEE_BALANCE || 
            (fees > 0 && block.timestamp > lastInterestUpdateTime[token] + 30 days),
            "Emergency conditions not met"
        );
        
        platformFeeBalance[token] = 0;
        IERC20(token).safeTransfer(recipient, fees);
        
        emit PlatformFeeCollected(token, fees, recipient);
    }
    
    /**
     * @dev Get interest statistics for a specific token
     * @param token Token address
     * @return totalInterest Total interest earned
     * @return platformFees Total platform fees collected
     * @return globalIndex Current global interest index
     * @return userBalanceTotal Total user balance
     */
    function getInterestStats(address token) external view returns (
        uint256 totalInterest,
        uint256 platformFees,
        uint256 globalIndex,
        uint256 userBalanceTotal
    ) {
        return (
            totalInterestEarned[token],
            platformFeesCollected[token],
            globalInterestIndex[token],
            totalUserBalance[token]
        );
    }
    
    /**
     * @dev Get user's interest information for a specific token
     * @param user User address
     * @param token Token address
     * @return userBalance User's current balance
     * @return lastIndex User's last interest index
     * @return currentIndex Current global interest index
     * @return pendingInterest User's pending interest
     * @return accumulatedInterest User's accumulated interest
     * @return totalClaimable Total interest user can claim
     */
    function getUserInterestInfo(address user, address token) external view returns (
        uint256 userBalance,
        uint256 lastIndex,
        uint256 currentIndex,
        uint256 pendingInterest,
        uint256 accumulatedInterest,
        uint256 totalClaimable
    ) {
        userBalance = pots[user][token].balance;
        lastIndex = userLastInterestIndex[user][token];
        currentIndex = globalInterestIndex[token];
        pendingInterest = calculateUserInterest(user, token);
        accumulatedInterest = userAccumulatedInterest[user][token];
        totalClaimable = pendingInterest + accumulatedInterest;
    }
    
    /**
     * @dev 컨트랙트 업그레이드를 승인하는 함수 (소유자만 업그레이드 가능)
     * @param newImplementation 새로운 구현 컨트랙트 주소
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @dev 컨트랙트를 새로운 구현으로 업그레이드하고 버전 업데이트
     * @param newImplementation 새로운 구현 컨트랙트 주소
     * @param data 새로운 구현에 전송할 선택적 데이터
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override onlyOwner {
        uint256 oldVersion = version;
        super.upgradeToAndCall(newImplementation, data);
        // 참고: 버전은 새로운 구현의 업그레이드 함수에서 업데이트됩니다
        emit ContractUpgraded(oldVersion, version, newImplementation);
    }
    
    /**
     * @dev 컨트랙트 버전 설정 (업그레이드 후 호출됨)
     * @param newVersion 새로운 버전 번호
     */
    function setVersion(uint256 newVersion) external onlyOwner {
        require(newVersion > version, "Version must be higher than current");
        version = newVersion;
    }
    
    /**
     * @dev 현재 컨트랙트 버전 조회
     * @return 현재 버전 번호
     */
    function getVersion() external view returns (uint256) {
        return version;
    }
    
    // 내부 함수들
    
    /**
     * @dev Aave에 토큰 공급
     * @param token 공급할 토큰 주소
     * @param amount 공급할 수량
     */
    function _supplyToAave(address token, uint256 amount) internal {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "No pool configured for token");
        
        // 토큰 승인
        IERC20(token).approve(address(config.pool), amount);
        
        // Aave에 공급 (토큰별 풀)
        config.pool.supply(token, amount, address(this), 0);
        
        // 첫 공급 시 aToken 주소 가져오기
        if (config.aToken == address(0)) {
            // aToken 주소를 찾기 위해 예약 데이터 가져오기
            DataTypes.ReserveData memory reserveData = config.pool.getReserveData(token);
            config.aToken = reserveData.aTokenAddress;
        }
        
        // 공급된 총량 업데이트
        totalSuppliedToAave[token] += amount;
        
        emit AaveSupplied(token, amount);
    }
    
    /**
     * @dev Aave에서 토큰 출금
     * @param token 출금할 토큰 주소
     * @param amount 출금할 수량
     */
    function _withdrawFromAave(address token, uint256 amount) internal {
        TokenConfig storage config = tokenConfigs[token];
        require(address(config.pool) != address(0), "No pool configured for token");
        require(config.aToken != address(0), "aToken not set for token");
        
        // 이자 계산을 위해 출금 전 잔액 기록
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        
        // Aave에서 출금 (기본 토큰 주소 사용)
        uint256 withdrawnAmount = config.pool.withdraw(token, amount, address(this));
        
        // 이 출금으로부터 획득한 이자 계산
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;
        
        // Safety check - should never receive less than requested
        require(actualReceived >= amount, "Aave withdrawal returned less than expected");
        
        // 요청한 것보다 많이 받았다면 그것은 이자
        if (actualReceived > amount) {
            uint256 interestAmount = actualReceived - amount;
            _distributeInterest(token, interestAmount);
        }
        
        // 공급된 총량 업데이트
        if (totalSuppliedToAave[token] >= withdrawnAmount) {
            totalSuppliedToAave[token] -= withdrawnAmount;
        } else {
            totalSuppliedToAave[token] = 0;
        }
        
        emit AaveWithdrawn(token, withdrawnAmount);
    }
    
    /**
     * @dev 자동으로 빌릴 수 있는 만큼 대출 실행
     * @param token 담보 토큰 주소
     */
    function _autoBorrowFromAave(address token) internal returns (uint256 borrowedAmount) {
        TokenConfig storage config = tokenConfigs[token];
        require(config.borrowEnabled, "Borrow not enabled for this token");
        require(config.borrowGateway != address(0), "No borrow gateway configured");
        
        // 현재 계정 데이터 조회 (토큰별 풀)
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            ,
            uint256 healthFactor
        ) = config.pool.getUserAccountData(address(this));
        
        // 건강도가 충분하고 대출 가능한 금액이 있는 경우에만 대출
        if (healthFactor > 1.2e18 && availableBorrowsBase > 0) { // 건강도 1.2 이상
            // 목표 LTV에 맞춰 대출할 수 있는 최대 금액 계산
            uint256 targetDebt = (totalCollateralBase * targetLTV) / 10000;
            
            // 이미 빌린 금액을 고려하여 추가로 빌릴 수 있는 금액 계산
            if (targetDebt > totalDebtBase) {
                uint256 additionalBorrowAmount = targetDebt - totalDebtBase;
                
                // 실제 대출 가능 금액과 비교하여 더 작은 값 선택
                uint256 borrowAmount = additionalBorrowAmount < availableBorrowsBase 
                    ? additionalBorrowAmount 
                    : availableBorrowsBase;
                
                // 최소 대출 금액 체크 (가스 비용 고려)
                if (borrowAmount > 1e15) { // 0.001 토큰 이상일 때만 대출
                    _executeBorrow(token, config, borrowAmount);
                    return borrowAmount;
                }

                return 0;
            }

            return 0;
        }

        return 0;
    }
    
    // Aave 통합을 위한 헬퍼 함수들
        
    /**
    * @dev 토큰 설정 구성 (내부 함수)
    */
    function _setupTokenConfig(
        address token,
        IPool pool,
        bool supplyEnabled,
        bool borrowEnabled,
        address borrowToken,
        address borrowGateway,
        address debtToken,
        uint8 decimals
    ) internal {
        tokenConfigs[token] = TokenConfig({
            pool: pool,
            aToken: address(0), // Will be set when first supplied
            supplyEnabled: supplyEnabled,
            borrowEnabled: borrowEnabled,
            borrowToken: borrowToken,
            borrowGateway: borrowGateway,
            debtToken: debtToken,
            maxSupply: type(uint256).max,
            maxBorrow: type(uint256).max,
            decimals: decimals
        });
    }
    
    /**
     * @dev 대출 실행 (내부 함수)
     */
    function _executeBorrow(address token, TokenConfig memory config, uint256 amount) internal {
        require(config.debtToken != address(0), "Debt token not configured");
        IVariableDebtToken(config.debtToken).approveDelegation(config.borrowGateway, amount);

        try IWrappedTokenGatewayV3(config.borrowGateway).borrowETH(
            address(config.pool), 
            amount,
            2, // 가변 이율
            0
        ) {
            emit AaveBorrowed(config.borrowToken, amount);
        } catch Error(string memory reason) {
            emit AaveBorrowFailed(config.borrowToken, amount, reason);
        } catch {
            // Handle non-string errors (low-level failures)
            emit AaveBorrowFailed(config.borrowToken, amount, "Unknown error");
        }
    }
    
    /**
     * @dev 대출 상환 실행 (내부 함수)
     */
    function _executeRepay(address token, TokenConfig memory config, uint256 amount) internal {
        try IWrappedTokenGatewayV3(config.borrowGateway).repayETH{
            value: amount
        }(
            address(config.pool), 
            amount, 
            2,
            address(this)
        ) {
            emit AaveRepaid(config.borrowToken, amount);
        } catch Error(string memory reason) {
            // Log the error and revert
            revert(string(abi.encodePacked("Aave repay failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            // Handle non-string errors (low-level failures)
            revert("Aave repay failed: Unknown error");
        }
    }
    
    /**
     * @dev 이자 분배 및 플랫폼 수수료 수집
     * @param token 토큰 주소
     * @param interestAmount 분배할 총 이자 금액
     */
    function _distributeInterest(address token, uint256 interestAmount) internal {
        if (interestAmount == 0) return;
        
        // 플랫폼 수수료 계산 (15%)
        uint256 platformFee = (interestAmount * platformFeePercentage) / 10000;
        uint256 userInterest = interestAmount - platformFee;
        
        // 고정밀도로 전역 이자 지수 업데이트
        // 이는 작은 잔액에 대한 정밀도 손실을 방지합니다
        if (totalUserBalance[token] > 0) {
            // 더 나은 정확도를 위해 고정밀도 상수 사용
            globalInterestIndex[token] += (userInterest * INTEREST_PRECISION) / totalUserBalance[token];
        }
        
        // 총 획득 이자 업데이트
        totalInterestEarned[token] += userInterest;
        platformFeesCollected[token] += platformFee;
        
        // 마지막 이자 업데이트 시간 업데이트
        lastInterestUpdateTime[token] = block.timestamp;
        
        // 오버플로우 방지와 함께 플랫폼 수수료 누적
        if (platformFee > 0) {
            uint256 newBalance = platformFeeBalance[token] + platformFee;
                    // 누적이 최대치를 초과하면 초과분을 즉시 전송
        if (newBalance > MAX_PLATFORM_FEE_BALANCE) {
            uint256 excess = newBalance - MAX_PLATFORM_FEE_BALANCE;
            platformFeeBalance[token] = MAX_PLATFORM_FEE_BALANCE;
            // 초과분을 플랫폼 지갑으로 즉시 전송
            if (platformFeeWallet != address(0)) {
                IERC20(token).safeTransfer(platformFeeWallet, excess);
                emit PlatformFeeCollected(token, excess, platformFeeWallet);
            }
        } else {
            platformFeeBalance[token] = newBalance;
        }
        }
        
        emit InterestAccumulated(token, interestAmount, platformFee, userInterest);
        if (platformFee > 0) {
            emit PlatformFeeCollected(token, platformFee, platformFeeWallet);
        }
    }
    
    /**
     * @dev 잔액 변경 전에 사용자의 누적 이자 업데이트
     * @param user 사용자 주소
     * @param token 토큰 주소
     */
    function _updateUserInterest(address user, address token) internal {
        uint256 pending = calculateUserInterest(user, token);
        if (pending > 0) {
            userAccumulatedInterest[user][token] += pending;
            userLastInterestIndex[user][token] = globalInterestIndex[token];
        } else if (userLastInterestIndex[user][token] == 0 && globalInterestIndex[token] > 0) {
            // 첫 번째 사용자 - 획득하지 않은 이자를 청구하지 않도록 마지막 지수를 현재로 설정
            userLastInterestIndex[user][token] = globalInterestIndex[token];
        }
    }

    // Governance Council Delegation Management Functions
    
    /**
     * @dev 거버넌스 카운실 멤버의 PublicDelegation 컨트랙트 추가
     * @param publicDelegationAddr 추가할 PublicDelegation 컨트랙트 주소
     */
    function addGovernanceCouncilMember(address payable publicDelegationAddr) 
        external 
        onlyOwner 
        validAddress(publicDelegationAddr) 
    {
        // 이미 존재하는지 확인
        for (uint256 i = 0; i < governanceCouncilMembers.length; i++) {
            require(governanceCouncilMembers[i] != publicDelegationAddr, "PublicDelegation already exists");
        }
        
        governanceCouncilMembers.push(publicDelegationAddr);
        
        // 첫 번째 멤버라면 현재 활성 멤버로 설정
        if (governanceCouncilMembers.length == 1) {
            currentGovernanceCouncilMemberAddress = publicDelegationAddr;
        }
        
        emit GovernanceCouncilMemberAdded(publicDelegationAddr);
    }
    
    /**
     * @dev 거버넌스 카운실 멤버의 PublicDelegation 컨트랙트 제거
     * @param publicDelegationAddr 제거할 PublicDelegation 컨트랙트 주소
     */
    function removeGovernanceCouncilMember(address payable publicDelegationAddr) 
        external 
        onlyOwner 
        validAddress(publicDelegationAddr) 
    {
        uint256 index = type(uint256).max;
        
        // 인덱스 찾기
        for (uint256 i = 0; i < governanceCouncilMembers.length; i++) {
            if (governanceCouncilMembers[i] == publicDelegationAddr) {
                index = i;
                break;
            }
        }
        
        require(index != type(uint256).max, "PublicDelegation not found");
        
        // 현재 활성 멤버를 제거하는 경우 재설정
        if (publicDelegationAddr == currentGovernanceCouncilMemberAddress) {
            currentGovernanceCouncilMemberAddress = payable(address(0));
        }
        
        // 마지막 요소를 이 위치로 이동하여 제거
        uint256 lastIndex = governanceCouncilMembers.length - 1;
        if (index != lastIndex) {
            governanceCouncilMembers[index] = governanceCouncilMembers[lastIndex];
        }
        
        governanceCouncilMembers.pop();
        
        emit GovernanceCouncilMemberRemoved(publicDelegationAddr);
    }
    
    /**
     * @dev 현재 활성 거버넌스 카운실 멤버 설정
     * @param publicDelegationAddr 활성으로 설정할 PublicDelegation 컨트랙트 주소
     */
    function setCurrentGovernanceCouncilMember(address payable publicDelegationAddr) 
        external 
        onlyOwner 
        validAddress(publicDelegationAddr) 
    {
        // 주소가 거버넌스 카운실 멤버 목록에 존재하는지 확인
        bool exists = false;
        for (uint256 i = 0; i < governanceCouncilMembers.length; i++) {
            if (governanceCouncilMembers[i] == publicDelegationAddr) {
                exists = true;
                break;
            }
        }
        
        require(exists, "PublicDelegation not in governance council members list");
        
        currentGovernanceCouncilMemberAddress = publicDelegationAddr;
        
        emit CurrentGovernanceCouncilMemberSet(publicDelegationAddr);
    }
    
    /**
     * @dev Stake KAIA tokens to the current governance council member's publicDelegation
     * @param amount Amount of KAIA tokens to stake
     */
    function _stakeToGovernanceCouncil(uint256 amount) 
        internal
        whenNotPaused 
        validAmount(amount) 
    {
        require(currentGovernanceCouncilMemberAddress != address(0), "No active governance council member");
        require(msg.value == amount, "Incorrect amount sent");
        
        // 현재 멤버의 PublicDelegation 컨트랙트에 스테이킹
        IPublicDelegation(currentGovernanceCouncilMemberAddress).stake{value: amount}();
        
        emit DelegationStaked(currentGovernanceCouncilMemberAddress, amount);
    }
    
    /**
     * @dev Withdraw KAIA tokens from a specific governance council member's delegation
     * @param publicDelegationAddr The publicDelegation contract address to withdraw from
     * @param amount Amount of KAIA tokens to withdraw
     */
    function withdrawFromGovernanceCouncil(address payable publicDelegationAddr, uint256 amount) 
        external 
        onlyOwner 
        nonReentrant 
        whenNotPaused 
        validAmount(amount) 
        validAddress(publicDelegationAddr)
    {
        // 주소가 거버넌스 카운실 멤버 목록에 존재하는지 확인
        bool exists = false;
        for (uint256 i = 0; i < governanceCouncilMembers.length; i++) {
            if (governanceCouncilMembers[i] == publicDelegationAddr) {
                exists = true;
                break;
            }
        }
        
        require(exists, "PublicDelegation not in governance council members list");
        
        // 지정된 멤버의 PublicDelegation 컨트랙트에서 출금
        IPublicDelegation(publicDelegationAddr).withdraw(address(this), amount);
        
        emit DelegationWithdrawn(publicDelegationAddr, amount);
    }
    
    /**
     * @dev 거버넌스 카운실 위임에서 사용 가능한 모든 KAIA 토큰 청구
     * 이 함수는 청구를 처리하기 위해 매시간 외부에서 호출되어야 합니다
     */
    function claimAllAvailable() 
        external 
        onlyOwner
        nonReentrant 
        whenNotPaused 
    {
        _claimAllAvailable();
    }
    
    /**
     * @dev 사용 가능한 모든 KAIA 토큰을 청구하는 내부 함수
     * 모든 거버넌스 카운실 멤버를 처리하고 7일 지연을 통과한 토큰을 청구합니다
     */
    function _claimAllAvailable() internal {
        uint256 totalMembers = governanceCouncilMembers.length;
        
        for (uint256 i = 0; i < totalMembers; i++) {
            address payable publicDelegationAddr = governanceCouncilMembers[i];
            _processMemberClaims(publicDelegationAddr);
        }
    }
    
    /**
     * @dev 특정 멤버에 대한 청구 처리
     * @param publicDelegationAddr 청구를 처리할 PublicDelegation 컨트랙트 주소
     */
    function _processMemberClaims(address payable publicDelegationAddr) internal {
        // PublicDelegation 컨트랙트에서 이 멤버의 모든 출금 요청 가져오기
        uint256 requestCount = IPublicDelegation(publicDelegationAddr).getUserRequestCount(address(this));
        
        for (uint256 i = 0; i < requestCount; i++) {
            uint256 requestId = IPublicDelegation(publicDelegationAddr).userRequestIds(address(this), i);
            IPublicDelegation.WithdrawalRequestState state = IPublicDelegation(publicDelegationAddr).getCurrentWithdrawalRequestState(requestId);
            
            // 요청이 출금 가능 상태(7일 경과)라면 청구
            if (state == IPublicDelegation.WithdrawalRequestState.Withdrawable) {
                IPublicDelegation(publicDelegationAddr).claim(requestId);
                emit DelegationClaimed(publicDelegationAddr, 0); // 금액은 로컬에서 추적되지 않음
            }
        }
    }
    
    /**
     * @dev PublicDelegation 컨트랙트에서 모든 거버넌스 카운실 멤버의 위임 정보 조회
     * @return publicDelegationAddrs 모든 PublicDelegation 컨트랙트 주소 배열
     * @return totalDelegated 각 멤버별 총 위임 금액 배열
     * @return totalWithdrawn 각 멤버별 총 출금 금액 배열
     * @return pendingClaims 각 멤버별 대기 중인 청구 수 배열
     */
    function getDelegationInfo() 
        external 
        view 
        returns (
            address[] memory publicDelegationAddrs,
            uint256[] memory totalDelegated,
            uint256[] memory totalWithdrawn,
            uint256[] memory pendingClaims
        ) 
    {
        uint256 memberCount = governanceCouncilMembers.length;
        
        publicDelegationAddrs = new address[](memberCount);
        totalDelegated = new uint256[](memberCount);
        totalWithdrawn = new uint256[](memberCount);
        pendingClaims = new uint256[](memberCount);
        
        for (uint256 i = 0; i < memberCount; i++) {
            address payable publicDelegationAddr = governanceCouncilMembers[i];
            publicDelegationAddrs[i] = publicDelegationAddr;
            
            // PublicDelegation 컨트랙트에서 정보 가져오기
            totalDelegated[i] = IPublicDelegation(publicDelegationAddr).totalAssets();
            totalWithdrawn[i] = 0; // 컨트랙트에서 직접 사용할 수 없음
            
            // 대기 중인 출금 요청 수 계산
            uint256 requestCount = IPublicDelegation(publicDelegationAddr).getUserRequestCount(address(this));
            pendingClaims[i] = 0;
            
            for (uint256 j = 0; j < requestCount; j++) {
                uint256 requestId = IPublicDelegation(publicDelegationAddr).userRequestIds(address(this), j);
                IPublicDelegation.WithdrawalRequestState state = IPublicDelegation(publicDelegationAddr).getCurrentWithdrawalRequestState(requestId);
                
                if (state == IPublicDelegation.WithdrawalRequestState.Requested) {
                    pendingClaims[i]++;
                }
            }
        }
    }
    
    /**
     * @dev 모든 거버넌스 카운실 멤버의 모든 출금 요청 ID 조회
     * @return publicDelegationAddrs 모든 PublicDelegation 컨트랙트 주소 배열
     * @return requestIds 각 멤버별 요청 ID를 포함하는 배열의 배열
     */
    function getDelegationRequestIds() 
        external 
        view 
        returns (
            address[] memory publicDelegationAddrs,
            uint256[][] memory requestIds
        ) 
    {
        uint256 memberCount = governanceCouncilMembers.length;
        
        publicDelegationAddrs = new address[](memberCount);
        requestIds = new uint256[][](memberCount);
        
        for (uint256 i = 0; i < memberCount; i++) {
            address payable publicDelegationAddr = governanceCouncilMembers[i];
            publicDelegationAddrs[i] = publicDelegationAddr;
            
            requestIds[i] = IPublicDelegation(publicDelegationAddr).getUserRequestIds(address(this));
        }
    }
    
    /**
     * @dev 모든 거버넌스 카운실 PublicDelegation 컨트랙트 주소 조회
     * @return 모든 PublicDelegation 컨트랙트 주소 배열
     */
    function getAllGovernanceCouncilMembers() 
        external 
        view 
        returns (address payable[] memory) 
    {
        return governanceCouncilMembers;
    }
    
    /**
     * @dev 거버넌스 카운실 멤버의 총 수 조회
     * @return 멤버의 총 수
     */
    function getGovernanceCouncilMemberCount() 
        external 
        view 
        returns (uint256) 
    {
        return governanceCouncilMembers.length;
    }
}

interface IVariableDebtToken {
      function approveDelegation(address delegatee, uint256 amount) external;
}
