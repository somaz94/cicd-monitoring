#!/bin/bash

###################
# 글로벌 변수 #
###################

# Elasticsearch 연결 설정
ELASTIC_USER="elastic"
ELASTIC_PASSWORD="somaz123!"
ELASTIC_HOST="http://elasticsearch.somaz.link"

# 정리할 인덱스 이름 (배열)
INDEX_NAMES=()

# 지정되지 않은 경우 기본 인덱스
DEFAULT_INDICES=("" "")

# 보존 기간 설정
# 최소 보존 일수
MIN_RETENTION_DAYS=7
# 기본 보존 기간 (일)
RETENTION_DAYS=30

# 강제 병합 플래그
FORCE_MERGE=false

# 날짜 형식
TODAY=$(date +%Y.%m.%d)

# 도움말 출력 함수
show_help() {
  cat << EOF
사용법: $(basename "$0") [옵션] [INDEX 이름들...]

설명:
  지정한 Elasticsearch 인덱스에서, 설정한 보존 기간보다 오래된 문서를 삭제합니다.

옵션:
  -h, --help              이 도움말 메시지를 출력합니다
  -d, --days DAYS         보존 기간 (일 단위, 기본: 30일, 최소: ${MIN_RETENTION_DAYS}일)
  -i, --indices LIST      삭제할 인덱스 이름 목록 (쉼표로 구분된 문자열)
  -l, --list              사용 가능한 모든 인덱스를 나열합니다
  -s, --status            모든 인덱스의 상태를 출력합니다
  -f, --force-merge       삭제 후 디스크 최적화를 위한 강제 병합 실행

예시:
  $(basename "$0")                                # 기본 인덱스를 30일 기준으로 정리
  $(basename "$0") -d 60                          # 기본 인덱스를 60일 기준으로 정리
  $(basename "$0") index1 index2                  # 특정 인덱스를 30일 기준으로 정리
  $(basename "$0") -d 60 index1 index2            # 특정 인덱스를 60일 기준으로 정리
  $(basename "$0") -i "index1,index2" -d 60       # 쉼표로 구분된 인덱스를 60일 기준으로 정리
  $(basename "$0") -l                             # 인덱스 목록 보기
  $(basename "$0") -s                             # 인덱스 상태 확인
  $(basename "$0") -f index1                      # index1 삭제 후 강제 병합 실행
  $(basename "$0") -d 60 -f index1 index2         # index1, index2를 60일 기준 삭제 + 병합

기본 삭제 대상 인덱스: ${DEFAULT_INDICES[@]}

⚠️ 참고: 안전을 위해 최소 보존 기간은 ${MIN_RETENTION_DAYS}일입니다.
EOF
  exit 0
}

# 명령행 인수 파싱
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -d|--days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -i|--indices)
            IFS=',' read -ra INDEX_NAMES <<< "$2"
            shift 2
            ;;
        -l|--list)
            echo "사용 가능한 인덱스:"
            curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices?v" | awk 'NR>1 {print $3}' | sort
            exit 0
            ;;
        -s|--status)
            echo "모든 인덱스의 현재 상태:"
            curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices"
            exit 0
            ;;
        -f|--force-merge)
            FORCE_MERGE=true
            shift
            ;;
        -*)
            echo "알 수 없는 옵션: $1" >&2
            echo "자세한 정보는 '$(basename $0) --help'를 참조하세요." >&2
            exit 1
            ;;
        *)
            INDEX_NAMES+=("$1")
            shift
            ;;
    esac
done

# RETENTION_DAYS 검증
if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "오류: 일수는 양의 정수여야 합니다" >&2
    echo "자세한 정보는 '$(basename $0) --help'를 참조하세요." >&2
    exit 1
fi

if [ "$RETENTION_DAYS" -lt "$MIN_RETENTION_DAYS" ]; then
    echo "오류: 보존 기간은 ${MIN_RETENTION_DAYS}일보다 작을 수 없습니다" >&2
    echo "자세한 정보는 '$(basename $0) --help'를 참조하세요." >&2
    exit 1
fi

# 인덱스가 지정되지 않은 경우 기본 인덱스 사용
if [ ${#INDEX_NAMES[@]} -eq 0 ]; then
    INDEX_NAMES=("${DEFAULT_INDICES[@]}")
fi

# OS 타입 확인하고 적절한 date 명령 사용
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    THRESHOLD_DATE=$(date -v-${RETENTION_DAYS}d -u +"%Y-%m-%dT%H:%M:%S.000Z")
else
    # Linux
    THRESHOLD_DATE=$(date -d "-${RETENTION_DAYS} days" -u +"%Y-%m-%dT%H:%M:%S.000Z")
fi

# 지정된 인덱스들을 반복하여 오래된 문서 삭제
echo "정리할 인덱스: ${INDEX_NAMES[@]}"
echo "보존 기간: ${RETENTION_DAYS}일"
echo "다음 날짜보다 오래된 문서를 삭제합니다: $THRESHOLD_DATE"
read -p "정말로 이 인덱스들에서 오래된 문서를 삭제하시겠습니까? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "작업이 취소되었습니다."
    exit 0
fi

for INDEX in "${INDEX_NAMES[@]}"; do
    echo "인덱스 처리 중: $INDEX"
    
    # 임계 날짜보다 오래된 문서 삭제
    DELETE_QUERY='{
        "query": {
            "range": {
                "@timestamp": {
                    "lt": "'$THRESHOLD_DATE'"
                }
            }
        }
    }'
    
    echo "${INDEX}에서 오래된 문서 삭제 중..."
    RESPONSE=$(curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
        -X POST "$ELASTIC_HOST/$INDEX/_delete_by_query" \
        -H "Content-Type: application/json" \
        -d "$DELETE_QUERY")
    
    # 삭제가 성공했는지 확인하고 삭제된 수 추출
    if echo "$RESPONSE" | grep -q '"deleted"'; then
        DELETED_COUNT=$(echo "$RESPONSE" | grep -o '"deleted":[0-9]*' | cut -d':' -f2)
        echo "✓ 인덱스 ${INDEX}에서 ${DELETED_COUNT}개 문서를 성공적으로 삭제했습니다"
    else
        echo "✗ 인덱스 ${INDEX}에서 문서 삭제에 실패했습니다"
        echo "응답: $RESPONSE"
    fi

    # 강제 병합이 요청된 경우
    if [ "$FORCE_MERGE" = true ]; then
        echo "인덱스 강제 병합 중: ${INDEX}..."
        MERGE_RESPONSE=$(curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
            -X POST "$ELASTIC_HOST/$INDEX/_forcemerge?only_expunge_deletes=true" \
            -H "Content-Type: application/json")
        
        # 강제 병합이 성공했는지 확인
        if echo "$MERGE_RESPONSE" | grep -q '"successful"'; then
            echo "✓ 인덱스 ${INDEX}를 성공적으로 강제 병합했습니다"
        else
            echo "✗ 인덱스 ${INDEX} 강제 병합에 실패했습니다"
            echo "응답: $MERGE_RESPONSE"
        fi
    fi
    echo "---"
done

echo "문서 정리 프로세스가 완료되었습니다."
