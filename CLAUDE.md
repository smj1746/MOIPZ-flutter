# MOIP-Z 프로젝트 규칙

## Git 작업 금지 (최우선)

Claude Code는 아래 명령을 **절대 실행하지 않는다.**

- git add
- git commit
- git push
- git reset / git revert / git rebase
- git branch (생성, 삭제, 이름 변경 모두)
- git checkout / git switch
- git merge
- git update-ref
- git stash
- gh CLI 를 통한 PR 생성 및 머지

파일 수정까지만 하고 멈춘다.
커밋과 푸시는 항상 사용자가 직접 CMD 에서 수행한다.

작업이 끝나면 다음을 보고한다.
1. 변경한 파일 목록
2. 각 파일에서 무엇을 바꿨는지
3. 사용자가 실행할 git 명령어 (제안만, 실행 금지)

조회 전용 명령은 허용한다.
git status / git log / git diff / git branch -a / git ls-files

## 셸 환경

Windows CMD 기준으로 명령어를 제시한다.
- bash 문법 $( ) 사용 금지
- grep 대신 findstr 사용
- 경로 구분자는 백슬래시

## 커밋 메시지 규칙 (사용자가 직접 사용)

Conventional Commits + 한국어 본문
feat / fix / docs / refactor / chore / style / test

## 브랜치 전략

main      배포 가능 상태
develop   통합 브랜치
feature/frontend, feature/backend  작업 브랜치

## 보안

- API 키 등 비밀값은 lib/secrets.dart 에만 둔다
- lib/secrets.dart 는 .gitignore 대상이며 절대 커밋하지 않는다
- lib/secrets.example.dart 는 플레이스홀더만 담아 커밋한다
- 키를 코드에 하드코딩하지 않는다