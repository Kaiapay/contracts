// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/KaiaPayVault.sol";

/**
 * @title KaiaPayVault 업그레이드 스크립트
 * @dev 기존 KaiaPayVault 프록시를 새로운 구현으로 업그레이드
 * @dev UUPS 프록시 패턴을 사용하여 상태 데이터를 보존하면서 업그레이드
 */
contract UpgradeKaiaScript is Script {
    
    /**
     * @dev 메인 업그레이드 함수
     * @dev 환경변수에서 개인키와 프록시 주소를 가져와 업그레이드 실행
     */
    function run() external {
        // 환경변수에서 배포자 개인키 가져오기
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // 기존 프록시 주소 (환경변수에서 가져오거나 직접 설정)
        address payable proxyAddress = payable(vm.envAddress("PROXY_ADDRESS"));
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log(unicode"🔄 KaiaPayVault 업그레이드 시작");
        console.log(unicode"네트워크: Kaia Chain (8217)");
        console.log(unicode"업그레이더:", deployer);
        console.log(unicode"기존 프록시 주소:", proxyAddress);
        
        // 기존 컨트랙트 인스턴스 생성 (프록시 주소 사용)
        KaiaPayVault existingVault = KaiaPayVault(payable(proxyAddress));
        
        // 기존 버전 확인 (업그레이드 전 현재 버전)
        uint256 currentVersion = existingVault.getVersion();
        console.log(unicode"현재 버전:", currentVersion);
        
        // 새로운 구현 컨트랙트 배포
        console.log(unicode"📦 새로운 구현 컨트랙트 배포 중...");
        KaiaPayVault newImplementation = new KaiaPayVault();
        console.log(unicode"  ✅ 새로운 구현 컨트랙트 배포 완료:", address(newImplementation));
        
        // 업그레이드 데이터 준비 (필요시 초기화 함수 호출)
        bytes memory upgradeData = "";
        
        // 프록시 업그레이드 실행 (기존 상태 데이터 보존)
        console.log(unicode"⬆️  프록시 업그레이드 실행 중...");
        existingVault.upgradeToAndCall(address(newImplementation), upgradeData);
        
        // 업그레이드 후 버전 번호 업데이트
        console.log(unicode"📝 버전 업데이트 중...");
        existingVault.setVersion(currentVersion + 1);
        
        // 업그레이드 후 새로운 버전 확인
        uint256 newVersion = existingVault.getVersion();
        console.log(unicode"  ✅ 업그레이드 완료!");
        console.log(unicode"  이전 버전:", currentVersion);
        console.log(unicode"  새로운 버전:", newVersion);
        
        vm.stopBroadcast();
        
        // 업그레이드 완료 요약 정보 출력
        console.log("");
        console.log(unicode"🎉 KaiaPayVault 업그레이드 완료!");
        console.log(unicode"프록시 주소 (변경 없음):", proxyAddress);
        console.log(unicode"새로운 구현 주소:", address(newImplementation));
        console.log("");
        console.log(unicode"📋 업그레이드 후 확인사항:");
        console.log(unicode"1. 프록시 주소는 동일하게 유지");
        console.log(unicode"2. 모든 기존 상태 데이터 보존 확인");
        console.log(unicode"3. 새로운 기능 테스트");
        console.log(unicode"4. 버전 번호 업데이트 확인");
        console.log("");
        console.log(unicode"🔍 새로운 구현 컨트랙트 검증 명령어:");
        console.log(unicode"forge verify-contract", address(newImplementation), "src/KaiaPayVault.sol:KaiaPayVault --chain 8217 --verifier sourcify");
        console.log("");
        console.log(unicode"⚠️  중요: 업그레이드 후 확인사항");
        console.log(unicode"1. 기존 토큰 설정이 유지되는지 확인");
        console.log(unicode"2. 새로운 기능들이 정상 작동하는지 테스트");
        console.log(unicode"3. 버전 번호가 올바르게 업데이트되었는지 확인");
    }
}
