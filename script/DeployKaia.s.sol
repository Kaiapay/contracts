// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/KaiaPayVault.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KaiaPayVault 배포 스크립트
 * @dev Kaia Chain(8217)에서 KaiaPayVault를 배포하는 스크립트
 * @dev UUPS 프록시 패턴을 사용하여 업그레이드 가능한 컨트랙트로 배포
 */
contract DeployKaiaScript is Script {
    
    /**
     * @dev 메인 배포 함수
     * @dev 환경변수에서 개인키를 가져와 배포를 실행
     */
    function run() external {
        // 환경변수에서 배포자 개인키 가져오기
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log(unicode"🚀 Kaia 전용 KaiaPayVault 배포 시작");
        console.log(unicode"네트워크: Kaia Chain (8217)");
        console.log(unicode"배포자:", deployer);
        
        // Kaia 전용 토큰 설정 (USDT - 컨트랙트 초기화 시 기본 설정됨)
        address[] memory kaiaTokens = new address[](1);
        kaiaTokens[0] = 0xd077A400968890Eacc75cdc901F0356c943e4fDb; // USDT 토큰 주소
        
        console.log(unicode"Kaia 지원 토큰:");
        for (uint i = 0; i < kaiaTokens.length; i++) {
            console.log(unicode"  -", kaiaTokens[i]);
        }
        console.log(unicode"Kaia 대출 토큰: WKAIA (기본값)");
        console.log(unicode"Kaia 목표 LTV: 50% (기본값)");
        
        // 1단계: 구현 컨트랙트 배포
        console.log(unicode"📦 KaiaPayVault 구현 컨트랙트 배포 중...");
        KaiaPayVault implementation = new KaiaPayVault();
        console.log(unicode"  ✅ 구현 컨트랙트 배포 완료:", address(implementation));
        
        // 2단계: 초기화 데이터 준비 (소유자 설정)
        bytes memory initData = abi.encodeWithSelector(
            KaiaPayVault.initialize.selector,
            deployer
        );
        
        // 3단계: ERC1967 프록시 배포 (업그레이드 가능한 구조)
        console.log(unicode"🔗 ERC1967 프록시 배포 중...");
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log(unicode"  ✅ 프록시 배포 완료:", address(proxy));
        
        // 4단계: 프록시를 통해 KaiaPayVault 인터페이스로 래핑
        KaiaPayVault vault = KaiaPayVault(payable(address(proxy)));
        console.log(unicode"✅ KaiaPayVault (프록시) 배포 완료:", address(vault));
        
        // Kaia 전용 설정 적용
        console.log(unicode"🔧 Kaia 전용 설정 중...");
        
        // 지원 토큰 목록에 추가
        for (uint i = 0; i < kaiaTokens.length; i++) {
            vault.addSupportedToken(kaiaTokens[i]);
            console.log(unicode"  ✅ 지원 토큰 추가:", kaiaTokens[i]);
        }
        
        // USDT Aave 설정은 이미 initialize()에서 완료됨
        console.log(unicode"  ✅ USDT Aave 설정 완료 (초기화 시 설정됨)");
        
        // 향후 다른 토큰 Aave 활성화 예시 (관리자 참고용)
        console.log(unicode"  📝 향후 다른 토큰 Aave 활성화 예시:");
        console.log(unicode"    vault.setTokenConfig(token, pool, true, true, borrowToken, gateway, debtToken, decimals)");
        
        // 거버넌스 카운실 멤버 추가 (PublicDelegation 컨트랙트)
        vault.addGovernanceCouncilMember(payable(address(0x5089015830BdB2dD3bE51Cfaf20e7dBC659D4C05)));
        
        vm.stopBroadcast();
        
        // 배포 완료 요약 정보 출력
        console.log("");
        console.log(unicode"🎉 Kaia 전용 업그레이드 가능한 컨트랙트 배포 완료!");
        console.log(unicode"프록시 주소 (메인 컨트랙트):", address(vault));
        console.log(unicode"구현 컨트랙트 주소:", address(implementation));
        console.log(unicode"소유자:", deployer);
        console.log("");
        console.log(unicode"📋 배포 후 확인사항:");
        console.log(unicode"1. Kaia Explorer에서 프록시 컨트랙트 확인");
        console.log(unicode"2. 지원 토큰 설정 확인");
        console.log(unicode"3. 대출 토큰 설정 확인 (기본값 WKAIA)");
        console.log(unicode"4. LTV 설정 확인 (기본값 50%)");
        console.log(unicode"5. 업그레이드 권한 확인 (소유자만 가능)");
        console.log("");
        console.log(unicode"🔍 컨트랙트 검증 명령어:");
        console.log(unicode"# 구현 컨트랙트 검증:");
        console.log(unicode"forge verify-contract", address(implementation), "src/KaiaPayVault.sol:KaiaPayVault --chain 8217 --verifier sourcify");
        console.log(unicode"# 프록시 컨트랙트 검증:");
        console.log(unicode"forge verify-contract", address(proxy), "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --chain 8217 --verifier sourcify");
        console.log("");
        console.log(unicode"⚡ 향후 업그레이드 방법:");
        console.log(unicode"1. 새로운 구현 컨트랙트 배포");
        console.log(unicode"2. vault.upgradeToAndCall(newImplementation, \"\") 호출");
        console.log(unicode"3. 또는 업그레이드 스크립트 사용");
    }
}
