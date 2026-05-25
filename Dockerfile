# ==========================================
# 1. BASE IMAGE & SYSTEM DEPENDENCIES
# ==========================================
FROM freqtradeorg/freqtrade:stable

# สลับเป็นสิทธิ์ root ชั่วคราว เพื่อติดตั้งเครื่องมือและตั้งค่าระบบสิทธิ์ไฟล์
USER root

# ติดตั้งเครื่องมือพื้นฐานที่จำเป็นสำหรับการคอมไพล์ Python Package บางตัว
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ==========================================
# 2. PYTHON DEPENDENCIES (CUSTOM INDICATORS)
# ==========================================
COPY --chown=ftuser:ftuser requirements.txt* ./

RUN if [ -f requirements.txt ]; then \
        pip install --no-cache-dir -r requirements.txt; \
    fi

# ==========================================
# 3. COPY STRATEGIES & CONFIGURATION
# ==========================================
# copy strategiesเสริม จากเครื่องของเราเข้าไปใน Image โดยตรง
# วิธีนี้ทำให้เวลา Deploy ระบบจริง ตัว Image จะมีโค้ดกลยุทธ์ติดไปด้วยทันที ไม่เสี่ยงสูญหาย
COPY --chown=ftuser:ftuser user_data/strategies/ /freqtrade/user_data/strategies/

# คัดลอกไฟล์ congis หลัก และตั้งสิทธิ์ให้อยู่ภายใต้ชื่อผู้ใช้ ftuser
COPY --chown=ftuser:ftuser user_data/config.json* /freqtrade/user_data/config.json

# ==========================================
# 4. ENVIRONMENT & USER PRIVILEGES
# ==========================================
# สลับสิทธิ์กลับมาเป็นผู้ใช้ "ftuser" ซึ่งเป็นผู้ใช้ที่ไม่มีสิทธิ์ root (Non-root) เพื่อความปลอดภัย
USER ftuser

# แสดงพอร์ต 8080 เสมือนเป็นเอกสารอ้างอิงสำหรับการเชื่อมต่อ API Server
EXPOSE 8080