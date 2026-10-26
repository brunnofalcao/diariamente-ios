#!/usr/bin/env ruby
#
# add_app_localizations.rb
# ---------------------------------------------------------------------------
# Registra os idiomas do app no ios/App/App.xcodeproj SEM abrir o Xcode, com a
# gem `xcodeproj` (a mesma de scripts/add_widget_target.rb):
#
#   - developmentRegion = pt-BR (idioma principal; o Capacitor gera 'en');
#   - knownRegions com pt-BR, es e Base ('en' sai: o app nao tem nada em ingles);
#   - grupo de variantes InfoPlist.strings no grupo App, com os filhos
#     pt-BR.lproj/InfoPlist.strings e es.lproj/InfoPlist.strings, na build phase
#     Resources do target App.
#
# Por que: sem o grupo de variantes as pastas .lproj nao entram no .app, e o
# idioma fica so declarado no CFBundleLocalizations, sem os textos traduzidos
# (nome do app e pedido de permissao das Fotos). Com pt-BR e es de verdade no
# binario, o WKWebView de um iPhone em espanhol reporta navigator.language "es"
# e o site abre as telas iniciais em espanhol; os textos do sistema (folhas,
# alertas, permissoes) tambem saem em espanhol. Qualquer outro idioma do
# aparelho cai no pt-BR (CFBundleDevelopmentRegion).
#
# Onde roda: Codemagic, a partir da raiz do repo, no passo de idiomas do
# codemagic.yaml, DEPOIS do PlistBuddy no Info.plist e de add_widget_target.rb,
# ANTES de `pod install` / `xcode-project use-profiles`:
#
#     ruby scripts/add_app_localizations.rb
#
# Pre-condicoes:
#   - ios/App/App/<idioma>.lproj/InfoPlist.strings versionado para cada idioma
#     de LOCALES;
#   - Info.plist do App com CFBundleDevelopmentRegion pt-BR e todos os idiomas
#     de LOCALES no CFBundleLocalizations (o passo do codemagic.yaml grava isso).
#
# IDEMPOTENTE: rodar de novo nao duplica nada e, se o projeto ja esta certo, nao
# grava. O projeto so e gravado no fim; uma falha no meio nao deixa estado parcial.
#
# Variaveis de ambiente (todas opcionais):
#   L10N_PROJECT_PATH  .xcodeproj alvo (default: <raiz>/ios/App/App.xcodeproj)
#   L10N_REPO_ROOT     raiz do repo    (default: pasta pai de scripts/)
#   L10N_DRY_RUN=1     nao grava nada; imprime o project.pbxproj resultante no stdout
#
# Saida: 0 = ok | 1 = erro de entrada/verificacao | 2 = gem ausente
# ---------------------------------------------------------------------------

begin
  require 'xcodeproj'
rescue LoadError => e
  warn "ERRO: gem 'xcodeproj' nao encontrada (#{e.message})."
  warn 'No codemagic.yaml, imediatamente antes deste script, rode:'
  warn '  ruby -e "require \'xcodeproj\'" 2>/dev/null || gem install xcodeproj --no-document --user-install'
  exit 2
end

# O Info.plist tem acentos ("pílula"). Sem LANG em UTF-8 no shell, o Ruby le os
# arquivos como US-ASCII e a gem quebra ("invalid byte sequence in US-ASCII").
Encoding.default_external = Encoding::UTF_8

DEVELOPMENT_REGION = 'pt-BR'
# Idiomas com pasta .lproj de verdade. O CFBundleLocalizations do Info.plist tem
# estes e mais o 'pt' (Portugal), que usa os textos do proprio Info.plist.
LOCALES            = %w[pt-BR es].freeze
KNOWN_REGIONS      = (LOCALES + ['Base']).freeze
REMOVED_REGIONS    = %w[en].freeze
STRINGS_NAME       = 'InfoPlist.strings'
STRINGS_FILE_TYPE  = 'text.plist.strings'
APP_TARGET_NAME    = 'App'
APP_GROUP_PATH     = 'App'

DRY_RUN      = %w[1 true yes].include?(ENV['L10N_DRY_RUN'].to_s.downcase)
ROOT         = File.expand_path(ENV['L10N_REPO_ROOT'] || (__dir__ ? File.join(__dir__, '..') : Dir.pwd))
PROJECT_PATH = File.expand_path(ENV['L10N_PROJECT_PATH'] || File.join(ROOT, 'ios', 'App', 'App.xcodeproj'))

def step(msg)
  puts "==> #{msg}"
end

def info(msg)
  puts "    #{msg}"
end

def fail!(msg)
  warn "ERRO: #{msg}"
  exit 1
end

def variant_path(locale)
  "#{locale}.lproj/#{STRINGS_NAME}"
end

def app_target(project)
  project.targets.find { |t| t.name == APP_TARGET_NAME } || fail!("target '#{APP_TARGET_NAME}' nao encontrado")
end

# Grupo "App" do navegador (path App, logo abaixo do grupo principal).
def app_group(project)
  project.main_group.children.find do |c|
    c.isa == 'PBXGroup' && c.path.to_s == APP_GROUP_PATH
  end || fail!("grupo '#{APP_GROUP_PATH}' nao encontrado no grupo principal do projeto")
end

def infoplist_variant_groups(project)
  project.objects.select { |o| o.isa == 'PBXVariantGroup' && o.name.to_s == STRINGS_NAME }
end

# Le o Info.plist do App (INFOPLIST_FILE) e confere idioma principal e lista.
def check_info_plist!(app)
  rel = app.build_configurations.map { |c| c.build_settings['INFOPLIST_FILE'].to_s }.find { |v| !v.empty? }
  fail!("INFOPLIST_FILE vazio no target '#{APP_TARGET_NAME}'") unless rel
  path = File.join(File.dirname(PROJECT_PATH), rel)
  fail!("Info.plist nao encontrado: #{path}") unless File.file?(path)
  plist = Xcodeproj::Plist.read_from_path(path)
  region = plist['CFBundleDevelopmentRegion'].to_s
  langs  = Array(plist['CFBundleLocalizations']).map(&:to_s)
  info "#{rel}: CFBundleDevelopmentRegion=#{region} CFBundleLocalizations=#{langs.join(', ')}"
  fail!("CFBundleDevelopmentRegion deveria ser #{DEVELOPMENT_REGION} (veio #{region.inspect})") unless region == DEVELOPMENT_REGION
  missing = LOCALES - langs
  fail!("CFBundleLocalizations sem #{missing.join(', ')}") unless missing.empty?
end

def verify!(project)
  step 'Verificando resultado'
  root = project.root_object
  fail!("verificacao: developmentRegion = #{root.development_region}") unless root.development_region == DEVELOPMENT_REGION
  regions = Array(root.known_regions)
  missing = KNOWN_REGIONS - regions
  fail!("verificacao: knownRegions sem #{missing.join(', ')}") unless missing.empty?
  extra = regions & REMOVED_REGIONS
  fail!("verificacao: knownRegions ainda tem #{extra.join(', ')}") unless extra.empty?

  app   = app_target(project)
  group = app_group(project)
  groups = infoplist_variant_groups(project)
  fail!("verificacao: esperado 1 grupo de variantes #{STRINGS_NAME}, achei #{groups.size}") unless groups.size == 1
  variant = groups.first
  fail!("verificacao: #{STRINGS_NAME} fora do grupo #{APP_GROUP_PATH}") unless group.children.include?(variant)

  LOCALES.each do |loc|
    refs = variant.children.select { |c| c.path.to_s == variant_path(loc) }
    fail!("verificacao: #{variant_path(loc)} aparece #{refs.size} vezes no grupo de variantes") unless refs.size == 1
    ref = refs.first
    fail!("verificacao: nome do filho #{variant_path(loc)} = #{ref.name.inspect} (esperado #{loc})") unless ref.name.to_s == loc
    fail!("verificacao: tipo de #{variant_path(loc)} = #{ref.last_known_file_type}") unless ref.last_known_file_type == STRINGS_FILE_TYPE
    fail!("verificacao: #{ref.real_path} nao existe no disco") unless File.file?(ref.real_path.to_s)
  end

  in_app = app.resources_build_phase.files.count { |bf| bf.file_ref && bf.file_ref.uuid == variant.uuid }
  fail!("verificacao: #{STRINGS_NAME} aparece #{in_app} vezes em Resources do #{APP_TARGET_NAME}") unless in_app == 1
  project.targets.reject { |t| t.uuid == app.uuid }.each do |t|
    next unless t.respond_to?(:resources_build_phase) && t.resources_build_phase
    if t.resources_build_phase.files.any? { |bf| bf.file_ref && bf.file_ref.uuid == variant.uuid }
      fail!("verificacao: #{STRINGS_NAME} do App nao pode estar em Resources de '#{t.name}'")
    end
  end
  info "ok: developmentRegion=#{root.development_region}, knownRegions=#{regions.join(', ')}, " \
       "#{STRINGS_NAME} (#{LOCALES.join(', ')}) em Resources do #{APP_TARGET_NAME}"
end

def main
  step "Abrindo #{PROJECT_PATH}"
  fail!("projeto nao encontrado: #{PROJECT_PATH}") unless File.directory?(PROJECT_PATH)
  project = Xcodeproj::Project.open(PROJECT_PATH)
  info 'DRY RUN (nada sera gravado)' if DRY_RUN
  changes = []

  app   = app_target(project)
  group = app_group(project)
  app_dir = group.real_path.to_s

  # ---- 1. entradas -------------------------------------------------------
  step 'Conferindo Info.plist e InfoPlist.strings'
  check_info_plist!(app)
  LOCALES.each do |loc|
    path = File.join(app_dir, variant_path(loc))
    fail!("#{path} nao existe (versionado no repo em ios/App/App/#{variant_path(loc)})") unless File.file?(path)
    info "strings: #{variant_path(loc)}"
  end

  # ---- 2. idioma principal e knownRegions --------------------------------
  step 'developmentRegion e knownRegions'
  root = project.root_object
  if root.development_region != DEVELOPMENT_REGION
    changes << "developmentRegion #{root.development_region} -> #{DEVELOPMENT_REGION}"
    root.development_region = DEVELOPMENT_REGION
  end
  current = Array(root.known_regions)
  # Ordem fixa para os nossos; outros idiomas que alguem acrescentar ficam no fim.
  wanted = KNOWN_REGIONS + (current - KNOWN_REGIONS - REMOVED_REGIONS)
  if current != wanted
    changes << "knownRegions (#{current.join(', ')}) -> (#{wanted.join(', ')})"
    root.known_regions = wanted
  end
  info "developmentRegion=#{root.development_region} knownRegions=#{root.known_regions.join(', ')}"

  # ---- 3. grupo de variantes InfoPlist.strings ---------------------------
  step "Grupo de variantes #{STRINGS_NAME} no grupo #{APP_GROUP_PATH}"
  groups = infoplist_variant_groups(project)
  fail!("ja existem #{groups.size} grupos #{STRINGS_NAME} no projeto; arrume a mao antes") if groups.size > 1
  variant = groups.first
  if variant
    fail!("#{STRINGS_NAME} existe fora do grupo #{APP_GROUP_PATH}; arrume a mao antes") unless group.children.include?(variant)
    info 'grupo ja existia; reutilizando'
  else
    variant = group.new_variant_group(STRINGS_NAME)
    changes << "grupo #{STRINGS_NAME} criado"
  end

  LOCALES.each do |loc|
    ref = variant.children.find { |c| c.path.to_s == variant_path(loc) }
    unless ref
      ref = variant.new_reference(variant_path(loc))
      changes << "#{variant_path(loc)} no grupo"
    end
    # O Xcode mostra o filho pelo idioma (igual ao "Base" de Main.storyboard).
    if ref.name.to_s != loc
      ref.name = loc
      changes << "nome #{loc} em #{variant_path(loc)}"
    end
    if ref.last_known_file_type != STRINGS_FILE_TYPE
      ref.last_known_file_type = STRINGS_FILE_TYPE
      changes << "tipo #{STRINGS_FILE_TYPE} em #{variant_path(loc)}"
    end
    info "#{loc}: #{ref.real_path}"
  end

  # ---- 4. Resources do App -----------------------------------------------
  step "Resources do target #{APP_TARGET_NAME}"
  phase = app.resources_build_phase
  if phase.files.any? { |bf| bf.file_ref && bf.file_ref.uuid == variant.uuid }
    info "#{STRINGS_NAME} ja estava em Resources"
  else
    phase.add_file_reference(variant, true)
    changes << "#{STRINGS_NAME} em Resources do #{APP_TARGET_NAME}"
    info "#{STRINGS_NAME} adicionado a Resources"
  end

  # ---- 5. gravar + verificar ---------------------------------------------
  step 'Mudancas'
  if changes.empty?
    info 'nenhuma (projeto ja estava certo)'
  else
    changes.each { |c| info c }
  end

  if DRY_RUN
    verify!(project)
    require 'nanaimo'
    step 'DRY RUN: nada gravado. project.pbxproj resultante:'
    puts '-----8<----- project.pbxproj -----8<-----'
    Nanaimo::Writer::PBXProjWriter.new(project.to_ascii_plist, :pretty => true, :output => $stdout, :strict => false).write
    puts '-----8<---------------------------8<-----'
  elsif changes.empty?
    verify!(project)
  else
    step "Gravando #{File.join(PROJECT_PATH, 'project.pbxproj')}"
    project.save
    verify!(Xcodeproj::Project.open(PROJECT_PATH))
  end
  0
end

begin
  exit(main)
rescue SystemExit
  raise
rescue StandardError => e
  warn "ERRO inesperado: #{e.class}: #{e.message}"
  warn e.backtrace.first(12).map { |l| "  #{l}" }.join("\n") if e.backtrace
  exit 1
end
