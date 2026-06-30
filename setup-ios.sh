#!/bin/bash
# Setup do app iOS (Capacitor) — rode no Mac, dentro desta pasta.
# Pré-requisitos: Node instalado + Xcode instalado (grátis na App Store).
set -e

echo "==> Instalando Capacitor + plugins..."
npm init -y >/dev/null 2>&1 || true
npm install @capacitor/core @capacitor/cli @capacitor/ios @capacitor/push-notifications @capacitor/splash-screen

echo "==> Adicionando a plataforma iOS..."
npx cap add ios

echo "==> Sincronizando config..."
npx cap sync ios

echo "==> Abrindo no Xcode..."
npx cap open ios

echo ""
echo "PRONTO. O Xcode abriu. Agora siga o PASSO-A-PASSO-APPLE.md a partir da Parte 3."
