#!/usr/bin/env ruby
#
# add_widget_target.rb
# ---------------------------------------------------------------------------
# Adiciona o target "DiariamenteWidget" (WidgetKit app extension) ao
# ios/App/App.xcodeproj SEM abrir o Xcode, usando a gem `xcodeproj`
# (dependencia do CocoaPods — presente na imagem do Codemagic; e a mesma gem
# que `xcode-project use-profiles` usa por dentro, via code_signing_manager.rb).
#
# Onde roda: Codemagic, a partir da raiz do repo, DEPOIS de `npx cap sync ios`
# e ANTES de `pod install` / `xcode-project use-profiles`:
#
#     ruby scripts/add_widget_target.rb
#
# Pre-condicao: fontes do widget ja copiados para ios/App/DiariamenteWidget/
# (DiariamenteWidget.swift + Info.plist [+ *.xcassets opcional]).
#
# IDEMPOTENTE: se o target "DiariamenteWidget" ja existir, sai com 0 sem tocar
# no projeto. O projeto so e gravado no fim (escrita atomica) — uma falha no
# meio nao deixa estado parcial.
#
# Variaveis de ambiente (todas opcionais):
#   WIDGET_PROJECT_PATH  .xcodeproj alvo  (default: <raiz>/ios/App/App.xcodeproj)
#   WIDGET_SRC_DIR       pasta dos fontes (default: <dir do .xcodeproj>/DiariamenteWidget)
#   WIDGET_REPO_ROOT     raiz do repo     (default: pasta pai de scripts/)
#   DEVELOPMENT_TEAM     Team ID usado se o target App nao tiver DEVELOPMENT_TEAM
#   WIDGET_DRY_RUN=1     nao grava nada; imprime o project.pbxproj resultante no stdout
#
# Saida: 0 = ok (ou ja existia) | 1 = erro de entrada/verificacao | 2 = gem ausente
# ---------------------------------------------------------------------------

begin
  require 'xcodeproj'
rescue LoadError => e
  warn "ERRO: gem 'xcodeproj' nao encontrada (#{e.message})."
  warn 'No codemagic.yaml, imediatamente antes deste script, rode:'
  warn '  ruby -e "require \'xcodeproj\'" 2>/dev/null || gem install xcodeproj --no-document --user-install'
  exit 2
end
require 'pathname'

WIDGET_NAME         = 'DiariamenteWidget'
WIDGET_BUNDLE_ID    = 'club.diariamente.app.widget'
APP_TARGET_NAME     = 'App'
DEPLOYMENT_TARGET   = '16.0'
EMBED_PHASE_NAME    = 'Embed Foundation Extensions'
PLUGINS_DST_SPEC    = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:plug_ins] # "13"
APPEX_PRODUCT_TYPE  = Xcodeproj::Constants::PRODUCT_TYPE_UTI[:app_extension]              # com.apple.product-type.app-extension
RESOURCE_EXTENSIONS = %w[.xcassets .strings .json .png .jpg .jpeg .txt].freeze

DRY_RUN      = %w[1 true yes].include?(ENV['WIDGET_DRY_RUN'].to_s.downcase)
ROOT         = File.expand_path(ENV['WIDGET_REPO_ROOT'] || (__dir__ ? File.join(__dir__, '..') : Dir.pwd))
PROJECT_PATH = File.expand_path(ENV['WIDGET_PROJECT_PATH'] || File.join(ROOT, 'ios', 'App', 'App.xcodeproj'))
SRC_DIR      = File.expand_path(ENV['WIDGET_SRC_DIR'] || File.join(File.dirname(PROJECT_PATH), WIDGET_NAME))

def step(msg)
  puts "==> #{msg}"
end

def info(msg)
  puts "    #{msg}"
end

def warn_line(msg)
  puts "    AVISO: #{msg}"
end

def fail!(msg)
  warn "ERRO: #{msg}"
  exit 1
end

# Caminho real (resolve symlinks) mesmo quando o arquivo ainda nao existe:
# resolve o ancestral existente mais proximo e reanexa o resto.
def realish(path)
  return File.realpath(path) if File.exist?(path)
  File.join(realish(File.dirname(path)), File.basename(path))
end

def relative_to(base_dir, path)
  Pathname.new(realish(path)).relative_path_from(Pathname.new(realish(base_dir))).to_s
end

# Le um build setting do App na configuracao de mesmo nome; cai para qualquer
# configuracao do App e depois para o nivel de projeto. Retorna nil se vazio.
def setting_from(project, app, config_name, key)
  candidates = []
  cfg = app.build_configurations.find { |c| c.name == config_name }
  candidates << cfg.build_settings[key] if cfg
  candidates.concat(app.build_configurations.map { |c| c.build_settings[key] })
  pcfg = project.build_configurations.find { |c| c.name == config_name }
  candidates << pcfg.build_settings[key] if pcfg
  candidates.concat(project.build_configurations.map { |c| c.build_settings[key] })
  candidates.map { |v| v.to_s.strip }.find { |v| !v.empty? }
end

def verify!(project, expect_infoplist)
  step 'Verificando resultado'
  widget = project.targets.find { |t| t.name == WIDGET_NAME }
  fail!("verificacao: target '#{WIDGET_NAME}' ausente") unless widget
  app = project.targets.find { |t| t.name == APP_TARGET_NAME }
  fail!("verificacao: target '#{APP_TARGET_NAME}' ausente") unless app
  fail!("verificacao: product_type = #{widget.product_type}") unless widget.product_type == APPEX_PRODUCT_TYPE

  product = widget.product_reference
  fail!('verificacao: product_reference ausente') unless product
  unless project.products_group.children.any? { |c| c.uuid == product.uuid }
    fail!("verificacao: #{product.path} nao esta no grupo Products")
  end
  unless app.dependencies.any? { |d| d.target && d.target.uuid == widget.uuid }
    fail!('verificacao: dependencia App -> widget ausente')
  end

  embed = app.copy_files_build_phases.find { |ph| ph.dst_subfolder_spec.to_s == PLUGINS_DST_SPEC }
  fail!('verificacao: copy-files phase (PlugIns) ausente no App') unless embed
  bf = embed.files.find { |f| f.file_ref && f.file_ref.uuid == product.uuid }
  fail!('verificacao: .appex nao esta na phase de embed') unless bf
  attrs = (bf.settings || {})['ATTRIBUTES'] || []
  fail!('verificacao: RemoveHeadersOnCopy ausente no .appex') unless attrs.include?('RemoveHeadersOnCopy')

  fail!('verificacao: nenhum .swift em Sources do widget') if widget.source_build_phase.files.empty?
  if widget.resources_build_phase.files.any? { |f| f.file_ref && File.basename(f.file_ref.path.to_s) == 'Info.plist' }
    fail!('verificacao: Info.plist NAO pode estar em Resources (gera "Multiple commands produce Info.plist")')
  end

  required = %w[PRODUCT_BUNDLE_IDENTIFIER INFOPLIST_FILE GENERATE_INFOPLIST_FILE SWIFT_VERSION
                IPHONEOS_DEPLOYMENT_TARGET TARGETED_DEVICE_FAMILY MARKETING_VERSION
                CURRENT_PROJECT_VERSION CODE_SIGN_STYLE SKIP_INSTALL LD_RUNPATH_SEARCH_PATHS]
  widget.build_configurations.each do |cfg|
    bs = cfg.build_settings
    required.each { |k| fail!("verificacao: #{k} ausente em #{cfg.name}") if bs[k].to_s.empty? }
    fail!("verificacao: bundle id errado em #{cfg.name}: #{bs['PRODUCT_BUNDLE_IDENTIFIER']}") unless bs['PRODUCT_BUNDLE_IDENTIFIER'] == WIDGET_BUNDLE_ID
    fail!("verificacao: INFOPLIST_FILE errado em #{cfg.name}: #{bs['INFOPLIST_FILE']}") unless bs['INFOPLIST_FILE'] == expect_infoplist
    if bs.keys.any? { |k| k.to_s.start_with?('CODE_SIGN_IDENTITY[') }
      fail!("verificacao: CODE_SIGN_IDENTITY condicional sobrou em #{cfg.name}")
    end
    app_cfg = app.build_configurations.find { |c| c.name == cfg.name }
    next unless app_cfg
    %w[MARKETING_VERSION CURRENT_PROJECT_VERSION].each do |k|
      next if app_cfg.build_settings[k].to_s.empty?
      next if bs[k].to_s == app_cfg.build_settings[k].to_s
      fail!("verificacao: #{k} do widget (#{bs[k]}) != App (#{app_cfg.build_settings[k]}) em #{cfg.name}")
    end
  end
  info 'ok: target, Products, dependencia, embed phase (RemoveHeadersOnCopy), Sources, build settings'
end

def main
  step "Abrindo #{PROJECT_PATH}"
  fail!("projeto nao encontrado: #{PROJECT_PATH}") unless File.directory?(PROJECT_PATH)
  project = Xcodeproj::Project.open(PROJECT_PATH)
  project_dir = File.dirname(PROJECT_PATH)
  info "targets atuais: #{project.targets.map(&:name).join(', ')}"
  info "DRY RUN (nada sera gravado)" if DRY_RUN

  if (existing = project.targets.find { |t| t.name == WIDGET_NAME })
    info "target '#{WIDGET_NAME}' ja existe (#{existing.product_type}). Nada a fazer (idempotente)."
    return 0
  end

  app = project.targets.find { |t| t.name == APP_TARGET_NAME }
  fail!("target '#{APP_TARGET_NAME}' nao encontrado") unless app

  # ---- 1. fontes do widget ------------------------------------------------
  step "Conferindo fontes do widget em #{SRC_DIR}"
  all_entries    = Dir.glob(File.join(SRC_DIR, '*')).sort
  swift_paths    = all_entries.select { |p| File.extname(p).downcase == '.swift' }
  plist_path     = File.join(SRC_DIR, 'Info.plist')
  resource_paths = all_entries.select { |p| RESOURCE_EXTENSIONS.include?(File.extname(p).downcase) }
  (all_entries - swift_paths - resource_paths - [plist_path]).each do |p|
    warn_line "ignorado (nao e .swift, Info.plist ou recurso conhecido): #{File.basename(p)}"
  end

  if swift_paths.empty? || !File.file?(plist_path)
    msg = "esperado pelo menos 1 .swift e um Info.plist em #{SRC_DIR}. " \
          'Copie antes: mkdir -p ios/App/DiariamenteWidget && cp -R DiariamenteWidget/. ios/App/DiariamenteWidget/'
    fail!(msg) unless DRY_RUN
    warn_line "#{msg} (DRY RUN: seguindo com placeholders)"
    swift_paths = [File.join(SRC_DIR, "#{WIDGET_NAME}.swift")] if swift_paths.empty?
  end
  swift_paths.each    { |p| info "fonte:   #{File.basename(p)}" }
  resource_paths.each { |p| info "recurso: #{File.basename(p)}" }
  info "plist:   #{plist_path}"

  group_rel     = relative_to(project_dir, SRC_DIR)     # ex.: DiariamenteWidget
  infoplist_rel = relative_to(project_dir, plist_path)  # ex.: DiariamenteWidget/Info.plist
  info "INFOPLIST_FILE = #{infoplist_rel}"

  # ---- 2. grupo no navegador ---------------------------------------------
  step "Grupo '#{WIDGET_NAME}' (path relativo ao projeto: #{group_rel})"
  group = project.main_group.children.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXGroup) && [c.name, c.path].include?(WIDGET_NAME)
  end
  if group
    info 'grupo ja existia; reutilizando'
  else
    group = project.main_group.new_group(WIDGET_NAME, group_rel)
    app_group_idx = project.main_group.children.index { |c| c.respond_to?(:path) && c.path == 'App' }
    project.main_group.children.move(group, app_group_idx + 1) if app_group_idx # logo abaixo de "App" (cosmetico)
    info 'grupo criado'
  end

  # ---- 3. referencias de arquivo -----------------------------------------
  step 'Adicionando referencias de arquivo ao grupo'
  find_or_add = lambda do |abs_path|
    base = File.basename(abs_path)
    group.files.find { |f| f.path.to_s == base } || group.new_file(base)
  end
  swift_refs    = swift_paths.map { |p| find_or_add.call(p) }
  resource_refs = resource_paths.map { |p| find_or_add.call(p) }
  plist_ref     = find_or_add.call(plist_path) # so referencia; NUNCA vai para Resources
  (swift_refs + resource_refs + [plist_ref]).each { |r| info "ref: #{r.path} (#{r.last_known_file_type})" }

  # ---- 4. target ---------------------------------------------------------
  step "Criando target '#{WIDGET_NAME}' (#{APPEX_PRODUCT_TYPE}, iOS #{DEPLOYMENT_TARGET}, Swift)"
  widget = project.new_target(:app_extension, WIDGET_NAME, :ios, DEPLOYMENT_TARGET, project.products_group, :swift)
  info "produto: #{widget.product_reference.path} (#{widget.product_reference.explicit_file_type}) no grupo Products"

  # new_target linka Foundation.framework por um caminho de SDK fixo (ex.:
  # iPhoneOS18.0.sdk) que nao existe na imagem "xcode: latest". O Swift
  # auto-linka WidgetKit/SwiftUI/Foundation, entao removemos a referencia.
  widget.frameworks_build_phase.files.to_a.each do |bf|
    ref = bf.file_ref
    bf.remove_from_project
    ref.remove_from_project if ref && ref.build_files.empty?
  end
  ios_frameworks_group = project.frameworks_group['iOS']
  ios_frameworks_group.remove_from_project if ios_frameworks_group && ios_frameworks_group.children.empty?
  info 'Frameworks phase do widget: vazia (auto-link do Swift)'

  # ---- 5. sources / resources -------------------------------------------
  step 'Populando build phases do widget'
  swift_refs.each    { |r| widget.source_build_phase.add_file_reference(r, true) }
  resource_refs.each { |r| widget.resources_build_phase.add_file_reference(r, true) }
  info "Sources: #{widget.source_build_phase.files.size} | Resources: #{widget.resources_build_phase.files.size} | Info.plist fora de Resources"

  # ---- 6. build settings (Debug e Release) -------------------------------
  step 'Aplicando build settings'
  team = setting_from(project, app, 'Release', 'DEVELOPMENT_TEAM') || ENV['DEVELOPMENT_TEAM'].to_s.strip
  team = nil if team.to_s.empty?
  widget.build_configurations.each do |cfg|
    bs = cfg.build_settings
    bs['PRODUCT_NAME']               = '$(TARGET_NAME)'
    bs['PRODUCT_BUNDLE_IDENTIFIER']  = WIDGET_BUNDLE_ID
    bs['INFOPLIST_FILE']             = infoplist_rel
    bs['GENERATE_INFOPLIST_FILE']    = 'NO'
    bs['SWIFT_VERSION']              = '5.0'
    bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    bs['SDKROOT']                    = 'iphoneos'
    bs['TARGETED_DEVICE_FAMILY']     = '1,2'
    bs['MARKETING_VERSION']          = setting_from(project, app, cfg.name, 'MARKETING_VERSION') || '1.0'
    bs['CURRENT_PROJECT_VERSION']    = setting_from(project, app, cfg.name, 'CURRENT_PROJECT_VERSION') || '1'
    bs['CODE_SIGN_STYLE']            = 'Manual'
    bs['DEVELOPMENT_TEAM']           = team if team
    bs['SKIP_INSTALL']               = 'YES'
    bs['LD_RUNPATH_SEARCH_PATHS']    = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
    # Um CODE_SIGN_IDENTITY[sdk=iphoneos*] no target venceria o CODE_SIGN_IDENTITY
    # que `xcode-project use-profiles` grava. Garante que nao existe.
    bs.keys.select { |k| k.to_s.start_with?('CODE_SIGN_IDENTITY[') }.each { |k| bs.delete(k) }
    # A gem compara deployment target como string ('16.0' < '5' => true) e injeta
    # CLANG_ENABLE_OBJC_WEAK = NO. Inofensivo em Swift, mas incorreto; herda do projeto.
    bs.delete('CLANG_ENABLE_OBJC_WEAK')
    info "#{cfg.name}: MARKETING_VERSION=#{bs['MARKETING_VERSION']} CURRENT_PROJECT_VERSION=#{bs['CURRENT_PROJECT_VERSION']} " \
         "DEVELOPMENT_TEAM=#{team || '(nao definido: xcode-project use-profiles preenche)'}"
  end

  # ---- 7. TargetAttributes -----------------------------------------------
  attrs = project.root_object.attributes
  attrs['TargetAttributes'] ||= {}
  attrs['TargetAttributes'][widget.uuid] = { 'CreatedOnToolsVersion' => '15.0', 'ProvisioningStyle' => 'Manual' }

  # ---- 8. dependencia + embed no App -------------------------------------
  step "Dependencia #{APP_TARGET_NAME} -> #{WIDGET_NAME}"
  app.add_dependency(widget)

  step "Build phase '#{EMBED_PHASE_NAME}' no #{APP_TARGET_NAME} (dstSubfolderSpec=#{PLUGINS_DST_SPEC} = PlugIns)"
  embed = app.copy_files_build_phases.find { |ph| ph.dst_subfolder_spec.to_s == PLUGINS_DST_SPEC }
  if embed
    info "phase ja existia (#{embed.name.inspect}); reutilizando"
  else
    embed = app.new_copy_files_build_phase(EMBED_PHASE_NAME)
    embed.dst_subfolder_spec = PLUGINS_DST_SPEC
    embed.dst_path = ''
    embed.run_only_for_deployment_postprocessing = '0'
    res_idx = app.build_phases.index(app.resources_build_phase)
    app.build_phases.move(embed, res_idx + 1) if res_idx # logo apos Resources, antes de "[CP] Embed Pods Frameworks"
    info "phase criada na posicao #{app.build_phases.index(embed) + 1}/#{app.build_phases.size}"
  end
  build_file = embed.add_file_reference(widget.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  info "#{widget.product_reference.path} embutido com RemoveHeadersOnCopy"

  # ---- 9. gravar + verificar ---------------------------------------------
  if DRY_RUN
    verify!(project, infoplist_rel)
    require 'nanaimo'
    step 'DRY RUN: nada gravado. project.pbxproj resultante:'
    puts '-----8<----- project.pbxproj -----8<-----'
    Nanaimo::Writer::PBXProjWriter.new(project.to_ascii_plist, :pretty => true, :output => $stdout, :strict => false).write
    puts '-----8<---------------------------8<-----'
  else
    step "Gravando #{File.join(PROJECT_PATH, 'project.pbxproj')}"
    project.save
    verify!(Xcodeproj::Project.open(PROJECT_PATH), infoplist_rel)
  end

  step 'Resumo'
  info "target:     #{WIDGET_NAME} (#{WIDGET_BUNDLE_ID}), iOS >= #{DEPLOYMENT_TARGET}, Swift 5.0, TARGETED_DEVICE_FAMILY=1,2"
  info "Info.plist: #{infoplist_rel} (GENERATE_INFOPLIST_FILE=NO)"
  info "assinatura: CODE_SIGN_STYLE=Manual; profile/team/identity vem de 'xcode-project use-profiles'"
  info "            (exige provisioning profile de #{WIDGET_BUNDLE_ID} baixado por fetch-signing-files)"
  info 'scheme:     nenhum criado. O repo nao tem xcshareddata/xcschemes, o xcodebuild autogera;'
  info "            'build-ipa --scheme App' compila o widget via dependencia de target e o embute via copy-files."
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
