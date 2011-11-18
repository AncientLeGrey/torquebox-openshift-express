#! /usr/bin/env ruby

# This script takes the Java application template created from the
# JBoss AS7 cartridge on OpenShift Express and converts it to the Ruby
# application template suitable for use with TorqueBox.

require 'fileutils'
require 'rexml/document'

root = File.expand_path(File.dirname(__FILE__))

# Remove Java files
FileUtils.rm(File.join(root, 'pom.xml')) if File.exist?(File.join(root, 'pom.xml'))
FileUtils.rm_r(File.join(root, 'src')) if File.exist?(File.join(root, 'src'))
FileUtils.rm_r(File.join(root, 'deployments')) if File.exist?(File.join(root, 'deployments'))

# Ensure .openshift/config/modules directory exists
FileUtils.mkdir_p(File.join(root, '.openshift', 'config', 'modules'))
FileUtils.touch(File.join(root, '.openshift', 'config', 'modules', '.gitkeep'))

# Add TorqueBox bits to standalone.xml
modules = %w(bootstrap core cdi jobs security services web)
standalone_xml = File.join(root, '.openshift', 'config', 'standalone.xml')
doc = REXML::Document.new(File.read(standalone_xml))
extensions = doc.root.get_elements('extensions').first
jboss_config_done = false; extensions.each_element_with_attribute('module', "org.torquebox.bootstrap") {|e| jboss_config_done = true }
unless (jboss_config_done)
  modules.each do |name|
    extensions.add_element('extension', 'module'=>"org.torquebox.#{name}")
  end
  profiles = doc.root.get_elements('//profile')
  profiles.each do |profile|
    modules.each do |name|
      profile.add_element('subsystem', 'xmlns'=>"urn:jboss:domain:torquebox-#{name}:1.0")
    end
    scanner_subsystem = profile.get_elements("subsystem[@xmlns='urn:jboss:domain:deployment-scanner:1.0']").first
    scanner = scanner_subsystem.get_elements('deployment-scanner').first
    scanner.add_attribute('deployment-timeout', '1200')
  end
  File.open(File.join(root, '.openshift', 'config', 'standalone.xml'), 'w') do |file|
    doc.write(file, 4)
  end
end

# Add TorqueBox bits to .openshift/action_hooks/build
File.open(File.join(root, '.openshift', 'action_hooks', 'build'), 'wb') do |file|
  file.write(<<-END_OF_BUILD)
#!/bin/bash
# This is a simple build script, place your post-deploy but pre-start commands
# in this script.  This script gets executed directly, so it could be python,
# php, ruby, etc.

JRUBY_VERSION="1.6.5"
TORQUEBOX_BUILD="614"
RACK_ENV="production"

cd ${OPENSHIFT_DATA_DIR}

# Download a JRuby and plonk it next to our jboss.home.dir
if [ ! -d jruby-${JRUBY_VERSION} ]; then
    curl -o jruby-bin-${JRUBY_VERSION}.tar.gz "http://jruby.org.s3.amazonaws.com/downloads/${JRUBY_VERSION}/jruby-bin-${JRUBY_VERSION}.tar.gz"
    tar -xzf jruby-bin-${JRUBY_VERSION}.tar.gz
    rm jruby-bin-${JRUBY_VERSION}.tar.gz
    rm -rf jruby-${JRUBY_VERSION}/share/ri/1.8/system/*
    ln -sf jruby-${JRUBY_VERSION} jruby
fi

# Download a TorqueBox distribution and extract the modules
if [ ! -d ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/modules/org/torquebox ] && [ ! -d torquebox-${TORQUEBOX_BUILD}-modules ]; then
    curl -o torquebox-dist-modules.zip "http://repository-torquebox.forge.cloudbees.com/incremental/torquebox/${TORQUEBOX_BUILD}/torquebox-dist-modules.zip"
    unzip -d torquebox-${TORQUEBOX_BUILD}-modules torquebox-dist-modules.zip
    rm torquebox-dist-modules.zip
fi

if [ ! -d ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/modules/org/torquebox ]; then
    # Symlink TorqueBox modules into the app's .openshift/config/modules directory
    mkdir -p ${OPENSHIFT_REPO_DIR}/.openshift/config/modules/org
    ln -s ${OPENSHIFT_DATA_DIR}/torquebox-${TORQUEBOX_BUILD}-modules/torquebox ${OPENSHIFT_REPO_DIR}/.openshift/config/modules/org/torquebox
fi

# Add jruby to our path
export PATH=${OPENSHIFT_DATA_DIR}/jruby/bin:$PATH

# Set JRUBY_HOME if we need to
if ! grep 'jruby.home' ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/bin/standalone.conf > /dev/null; then
    # Copy the symlinked file to a new file
    mv ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/bin/standalone.conf ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/bin/standalone.conf.original
    cp ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/bin/standalone.conf.original ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/bin/standalone.conf
    echo -e "\\nJAVA_OPTS=\\"\\$JAVA_OPTS -Djruby.home=${OPENSHIFT_DATA_DIR}jruby\\"" >> ${OPENSHIFT_APP_DIR}${OPENSHIFT_APP_TYPE}/bin/standalone.conf
else
    echo "jruby.home has already been set."
fi

# Install Bundler if needed
if ! jruby -S gem list | grep bundler > /dev/null; then
    jruby -S gem install bundler
fi

# Install Rack if needed
if ! jruby -S gem list | grep rack > /dev/null; then
    jruby -S gem install rack
fi

# Install the TorqueBox gems if needed
if ! jruby -S gem list | grep "torquebox (2.x.incremental.${TORQUEBOX_BUILD})" > /dev/null; then
    jruby -S gem install torquebox --pre --source http://torquebox.org/2x/builds/${TORQUEBOX_BUILD}/gem-repo/
fi

# If .bundle isn't currently committed and a Gemfile is then bundle install
if [ ! -d ${OPENSHIFT_REPO_DIR}/.bundle ] && [ -f ${OPENSHIFT_REPO_DIR}/Gemfile ]; then
    jruby -J-Xmx192m -S bundle install --gemfile ${OPENSHIFT_REPO_DIR}/Gemfile
fi

# Ensure a deployments directory exists
mkdir -p ${OPENSHIFT_REPO_DIR}/deployments

# Create a deployment descriptor for this app
cat <<__EOF__ > ${OPENSHIFT_REPO_DIR}/deployments/app-knob.yml
---
application:
  root: ${OPENSHIFT_REPO_DIR}
environment:
  RACK_ENV: ${RACK_ENV}
__EOF__
touch ${OPENSHIFT_REPO_DIR}/deployments/app-knob.yml.dodeploy
  END_OF_BUILD
end

# Add Ruby application template
unless File.exist?(File.join(root, 'config.ru'))
  File.open(File.join(root, 'config.ru'), 'w') do |file|
    file.write(<<-END_OF_CONFIG_RU)
require 'rack/lobster'

map '/health' do
  health = proc do |env|
    [200, { "Content-Type" => "text/html" }, ["1"]]
  end
  run health
end

map '/lobster' do
  run Rack::Lobster.new
end

map '/' do
  welcome = proc do |env|
    [200, { "Content-Type" => "text/html" }, ["<!doctype html>
<html lang=\\"en\\">
<head>
  <meta charset=\\"utf-8\\">
  <meta http-equiv=\\"X-UA-Compatible\\" content=\\"IE=edge,chrome=1\\">
  <title>Welcome to OpenShift</title>
  <style>
  html { background: black; }
  body {
    background: #333;
    background: -webkit-linear-gradient(top, black, #666);
    background: -o-linear-gradient(top, black, #666);
    background: -moz-linear-gradient(top, black, #666);
    background: linear-gradient(top, black, #666);
    color: white;
    font-family: 'Liberation Sans', Verdana, Arial, Sans-serif;
    width: 40em;
    margin: 0 auto;
    padding: 3em;
  }
  a {
   color: #bfdce8;
  }
  
  h1 {
    text-transform: uppercase;
    -moz-text-shadow: 2px 2px 2px black;
    -webkit-text-shadow: 2px 2px 2px black;
    text-shadow: 2px 2px 2px black;
    background: #c00;
    width: 22.5em;
    margin: .5em -2em;
    padding: .3em 0 .3em 1.5em;
    position: relative;
  }
  h1:before {
    content: '';
    width: 0;
    height: 0;
    border: .5em solid #900;
    border-left-color: transparent;
    border-bottom-color: transparent;
    position: absolute;
    bottom: -1em;
    left: 0;
    z-index: -1000;
  }
  h1:after {
    content: '';
    width: 0;
    height: 0;
    border: .5em solid #900;
    border-right-color: transparent;
    border-bottom-color: transparent;
    position: absolute;
    bottom: -1em;
    right: 0;
    z-index: -1000;
  }
  h2 { 
    text-transform: uppercase; 
    margin: 2em 0 .5em;
  }
  
  pre {
    background: black;
    padding: 1em 0 0;
    -webkit-border-radius: 1em;
    -moz-border-radius: 1em;
    border-radius: 1em;
    color: #9cf;
  }
  
  ul { margin: 0; padding: 0; }
  li {
    list-style-type: none;
    padding: .5em 0;
  }
  </style>
</head>
<body>
  <img
    alt=\\"OpenShift logo\\"
    src=\\"data:image/png;base64,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
/w+9BQu2G5s85QAAAABJRU5ErkJggg==\\">
  <h1>
    Welcome to OpenShift
  </h1>
  <p>
    Place your application here
  </p>
  <p>
    In order to commit to your new project, go to your projects git repo (created with the rhc-create-app command).  Make your changes, then run:
  </p>
  <pre>
    git commit -a -m 'Some commit message'
    git push
  </pre>
  <p>
    Then reload this page.
  </p>
  
  <h2>
    What's next?
  </h2>
  <ul>
    <li>
      Why not visit us at <a href=\\"http://openshift.redhat.com\\">http://openshift.redhat.com</a>, or
    </li>
    <li>
      You could get help in the <a href=\\"http://www.redhat.com/openshift\\">OpenShift forums</a>, or
    </li>
    <li>
      You're welcome to come chat with us in our IRC channel at #openshift on freenode.net
    </li>
  </ul>
</body>
</html>
"]]
  end
  run welcome
end
  END_OF_CONFIG_RU
  end
end

def tb_ose_start_process(pname)
  IO.popen(pname) do |output|
    output.each { |line| puts "#{line}" }
  end
end

# Add java_to_ruby.rb to .gitignore
File.open('.gitignore', 'r+') do |file|
  lines = file.readlines
  file.write("java_to_ruby.rb\n") unless lines.index("java_to_ruby.rb\n")
end

setup_git = ARGV.index('--no-git').nil? && ARGV.index('-ng').nil?
setup_rails = ARGV.index('--setup-rails') || ARGV.index('-r')

if setup_git
  puts "Adding git directories.."
  system 'git add .openshift/'
  system 'git add config.ru'
  puts "Committing changes to git."
  system 'git commit -am "converted to torquebox."'
end

if setup_rails
  puts "#{ENV['TORQUEBOX_HOME']}"
  app_name = Dir.pwd.split(/[\/\\]/).last
  puts "Installing Rails for application #{app_name}..."
  STDOUT.sync = true
  tb_ose_start_process "jruby -S gem install rails"
  Dir.chdir('..')
  puts "The current dir is now #{Dir.pwd}"
  tb_ose_start_process "jruby -S rails new #{app_name} -m $TORQUEBOX_HOME/share/rails/template.rb -b $TORQUEBOX_HOME/share/rails/openshift_app_builder.rb --skip-bundle"
  puts "Done creating Rails app; now resolving bundle dependencies."
  Dir.chdir("#{app_name}")
  tb_ose_start_process "bundle install --without assets"
  if setup_git
    puts "Adding git directories and committing changes to git..."
    tb_ose_start_process 'find . -not -name java_to_ruby.rb -not -name tmp -not -name .bundle -maxdepth 1 | xargs git add'
    tb_ose_start_process "git commit -am \"Added rails application for app #{app_name}.\""
    puts "Changes committed."
  end
end
