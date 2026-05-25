#!/usr/bin/env bash

# หยุดการทำงานทันทีหากมีคำสั่งใด ๆ เกิดข้อผิดพลาด
set -eo pipefail

# ==========================================
# 1. ตรวจสอบและโหลดค่าสภาวะแวดล้อม (.env.production)
# ==========================================
if [ ! -f ".env.production" ]; then
    echo "❌ Error: .env.production file not found!"
    exit 1
fi

# โหลดตัวแปรสภาพแวดล้อมเข้าสู่กระบวนการทำงาน
set -a
source .env.production
set +a

# ตรวจสอบค่าตัวแปรสำคัญที่จำเป็นต่อการทำงาน
REQUIRED_VARS=(
    "DOCKER_USERNAME" 
    "DOCKER_PASSWORD" 
    "NAMESPACE" 
    "APP_NAME" 
    "STOP_TIMEOUT" 
    "MAX_WAIT_HEALTHCHECK" 
    "HOST_VOLUME_USER_DATA"
)

for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        echo "❌ Error: Required environment variable '$VAR' is not set."
        exit 1
    fi
done

DOCKER_REPO="${DOCKER_USERNAME}/${NAMESPACE}:${APP_NAME}"

# ==========================================
# 🚨 โหมดตรวจสอบและกำหนดเวอร์ชันในการรัน (รวมถึง Rollback ฉุกเฉิน)
# ==========================================
if [ -n "$1" ]; then
   COMMIT_HASH="$1"
   echo "🚨 EMERGENCY ROLLBACK MODE: Forcing version $COMMIT_HASH"
else
   COMMIT_HASH="$(git rev-parse --short HEAD)"
fi

IMAGE_NAME="${DOCKER_REPO}-${COMMIT_HASH}"

echo "📌 Deploying version: $IMAGE_NAME"
echo "=========================================="

# ==========================================
# 2. เริ่มกระบวนการดาวน์โหลดและเตรียมคอนเทนเนอร์
# ==========================================

echo "🔑 1/5: Logging into Docker Hub..."
echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin

echo "🚀 2/5: Pulling Docker image from Registry..."
docker pull "$IMAGE_NAME"

# ตรวจหา Container ปัจจุบันที่กำลังให้บริการ (ระบบ Blue/Green เพื่อลดเวลา Downtime)
if docker ps -a | grep -q "${APP_NAME}-blue"; then
   OLD_CONTAINER="${APP_NAME}-blue"
   NEW_CONTAINER="${APP_NAME}-green"
   NEW_PORT="8089"  # ใช้พอร์ตสำรองชั่วคราวเพื่อทำ Health Check ก่อนสลับบริการ
   ACTIVE_PORT="8088"
else
   OLD_CONTAINER="${APP_NAME}-green"
   NEW_CONTAINER="${APP_NAME}-blue"
   NEW_PORT="8089"  # ใช้พอร์ตสำรองชั่วคราวเพื่อทำ Health Check ก่อนสลับบริการ
   ACTIVE_PORT="8088"
fi

# ล้าง Container ตัวใหม่ที่อาจจะตกค้างหรือค้างระบบอยู่ก่อนหน้า
if docker ps -a --format '{{.Names}}' | grep -qx "$NEW_CONTAINER"; then
   echo "🧹 Removing leftover container: $NEW_CONTAINER"
   docker rm -f "$NEW_CONTAINER" || true
fi


echo "🟢 3/5: Starting new FreqTrade container ($NEW_CONTAINER) on testing port ($NEW_PORT)..."
# ใช้พอร์ตทดสอบชั่วคราว $NEW_PORT ในการทดสอบสถานะ Health Status ก่อนอัพเกรดพอร์ตจริง
docker run -d \
    --name "$NEW_CONTAINER" \
    --restart unless-stopped \
    -p "${NEW_PORT}:8080" \
    -v "${HOST_VOLUME_USER_DATA}:/freqtrade/user_data" \
    --env-file .env.production \
    --stop-timeout "$STOP_TIMEOUT" \
    --health-cmd "curl -fsS http://localhost:8080/api/v1/ping || exit 1" \
    --health-interval=5s \
    --health-timeout=3s \
    --health-retries=3 \
    "$IMAGE_NAME" \
    trade \
    --logfile /freqtrade/user_data/logs/freqtrade.log \
    --db-url sqlite:////freqtrade/user_data/tradesv3.sqlite \
    --config /freqtrade/user_data/config.json \
    --strategy SampleStrategy

# ==========================================
# 3. การตรวจสอบสถานะสุขภาพ (Healthcheck Monitoring)
# ==========================================
echo "⏳ 4/5: Waiting for $NEW_CONTAINER to become healthy..."
MAX_WAIT=$MAX_WAIT_HEALTHCHECK
WAIT_COUNT=0

while true; do
    STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$NEW_CONTAINER" 2>/dev/null || true)"

    if [ "$STATUS" == "healthy" ]; then
        echo -e "\n✅ $NEW_CONTAINER is healthy!"
        break
    elif [ "$STATUS" == "unhealthy" ]; then
        echo -e "\n❌ Error: $NEW_CONTAINER status is unhealthy!"
        docker logs --tail 100 "$NEW_CONTAINER"
        exit 1
    elif [ "$(docker inspect -f '{{.State.Status}}' "$NEW_CONTAINER")" == "exited" ]; then
        echo -e "\n❌ Error: $NEW_CONTAINER has exited unexpectedly!"
        docker logs --tail 100 "$NEW_CONTAINER"
        exit 1
    fi

    if [ "$WAIT_COUNT" -ge "$MAX_WAIT" ]; then
        echo -e "\n❌ Error: Timeout! $NEW_CONTAINER is still not healthy after $MAX_WAIT seconds."
        docker logs --tail 100 "$NEW_CONTAINER"
        exit 1
    fi

    sleep 1
    WAIT_COUNT=$((WAIT_COUNT+1))
    echo -n "."
done

# ==========================================
# 4. ขั้นตอนการสลับพอร์ต (Port Swap / Replacement)
# เนื่องจากไม่มี Reverse Proxy คุมเพื่อทำ Virtual Routing ในพอร์ตเดิม 
# ==========================================
echo "🔄 Transitioning $NEW_CONTAINER to Primary Port ($ACTIVE_PORT)..."

# เก็บข้อมูล Image ของ Container ปัจจุบันไว้สำหรับ Clean-up
OLD_IMAGE=""
if docker ps -a | grep -q "$OLD_CONTAINER"; then
    OLD_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$OLD_CONTAINER" 2>/dev/null || true)
    echo "🛑 Stopping and Removing old service: $OLD_CONTAINER..."
    docker stop -t "$STOP_TIMEOUT" "$OLD_CONTAINER" || true
    docker rm "$OLD_CONTAINER" || true
fi

# ทำการเปลี่ยนพอร์ตของ Container ตัวใหม่ ให้ผูกกับพอร์ตหลักของโฮสต์
# เนื่องจากไม่สามารถแก้พอร์ต Container หลังรันแล้วแบบ Hot-reload ได้ จึงทำการสร้างใหม่ด้วยความเร็วสูง
echo "⚡ Swapping Container configuration to use $ACTIVE_PORT..."
docker stop -t "$STOP_TIMEOUT" "$NEW_CONTAINER" || true
docker rm "$NEW_CONTAINER" || true

docker run -d \
    --name "$NEW_CONTAINER" \
    --restart unless-stopped \
    -p "${ACTIVE_PORT}:8080" \
    -v "${HOST_VOLUME_USER_DATA}:/freqtrade/user_data" \
    --env-file .env.production \
    --stop-timeout "$STOP_TIMEOUT" \
    --health-cmd "curl -fsS http://localhost:8080/api/v1/ping || exit 1" \
    --health-interval=10s \
    --health-timeout=3s \
    --health-retries=5 \
    "$IMAGE_NAME" \
    trade \
    --logfile /freqtrade/user_data/logs/freqtrade.log \
    --db-url sqlite:////freqtrade/user_data/tradesv3.sqlite \
    --config /freqtrade/user_data/config.json \
    --strategy SampleStrategy

echo "🟢 5/5: Primary port assignment completed. Clean-up phase..."

# ทำความสะอาดข้อมูลขยะ / Image เก่าเพื่อประหยัดสเปซดิสก์เซิร์ฟเวอร์
if [ -n "$OLD_IMAGE" ] && [ "$OLD_IMAGE" != "$IMAGE_NAME" ]; then
    echo "🗑️ Removing old image: $OLD_IMAGE"
    docker rmi "$OLD_IMAGE" || true
else
    echo "ℹ️ No old container image found to purge (First deployment or same image version used)."
fi

# Logout เพื่อความปลอดภัยสูงสุด
docker logout

# ลบไฟล์ Configuration/Credential ของเซิร์ฟเวอร์
echo "🧹 Cleaning up temporary environment files..."
rm -f .env.production

echo "🧹 Pruning dangling docker images..."
docker image prune -f

echo "=========================================="
echo "🎉 Deployment Successful! Live on <IP>:${ACTIVE_PORT}"