# -*- encoding: utf-8 -*-
#
# Author:: Masashi Terui (<marcy9114@gmail.com>)
#
# Copyright (C) 2014, Masashi Terui
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'kitchen'

module Kitchen

  module Driver

    # Docker CLI driver for Kitchen.
    #
    # @author Masashi Terui <marcy9114@gmail.com>
    class DockerCli < Kitchen::Driver::Base

      default_config :no_cache, false
      default_config :command, 'sh -c \'while true; do sleep 1d; done;\''
      default_config :privileged, false

      default_config :image do |driver|
        driver.default_image
      end

      default_config :platform do |driver|
        driver.default_platform
      end

      def default_image
        platform, version = instance.platform.name.split('-')
        if platform == 'centos' && version
          version = "centos#{version.split('.').first}"
        end
        version ? [platform, version].join(':') : platform
      end

      def default_platform
        instance.platform.name.split('-').first
      end

      def create(state)
        state[:image] = build unless state[:image]
        state[:container_id] = run(state[:image]) unless state[:container_id]
      end

      def converge(state)
        provisioner = instance.provisioner
        provisioner.create_sandbox

        execute(docker_exec_command(state[:container_id], provisioner.install_command, :tty => true)) if provisioner.install_command
        execute(docker_exec_command(state[:container_id], provisioner.init_command, :tty => true)) if provisioner.init_command
        execute(docker_pre_transfer_command(provisioner, state[:container_id]))
        run_command(docker_transfer_command(provisioner, state[:container_id]))
        execute(docker_exec_command(state[:container_id], provisioner.prepare_command, :tty => true)) if provisioner.prepare_command
        execute(docker_exec_command(state[:container_id], provisioner.run_command, :tty => true)) if provisioner.run_command

      ensure
        provisioner && provisioner.cleanup_sandbox
      end

      def setup(state)
        if busser.setup_cmd
          execute(docker_exec_command(state[:container_id], busser.setup_cmd, :tty => true))
        end
      end

      def verify(state)
        if busser.sync_cmd
          execute(docker_exec_command(state[:container_id], busser.sync_cmd, :tty => true))
        end
        if busser.run_cmd
          execute(docker_exec_command(state[:container_id], busser.run_cmd, :tty => true))
        end
      end

      def destroy(state)
        execute("rm -f #{state[:container_id]}") rescue false
      end

      def remote_command(state, cmd)
        execute(docker_exec_command(state[:container_id], cmd))
      end

      def login_command(state)
        args = []
        args << 'exec'
        args << '-t'
        args << '-i'
        args << state[:container_id]
        args << '/bin/bash'
        LoginCommand.new(['docker', *args])
      end

      def build
        output = execute(docker_build_command, :input => docker_file)
        parse_image_id(output)
      end

      def run(image)
        output = execute(docker_run_command(image))
        parse_container_id(output)
      end

      def docker_command(cmd)
        "docker #{cmd}"
      end

      def docker_build_command
        cmd = 'build'
        cmd << ' --no-cache' if config[:no_cache]
        cmd << ' -'
      end

      def docker_run_command(image)
        cmd = "run -d"
        cmd << " --name #{config[:container_name]}" if config[:container_name]
        cmd << ' -P' if config[:publish_all]
        cmd << " -m #{config[:memory_limit]}" if config[:memory_limit]
        cmd << " -c #{config[:cpu_shares]}" if config[:cpu_shares]
        cmd << ' --privileged' if config[:privileged]
        Array(config[:publish]).each { |pub| cmd << " -p #{pub}" }
        Array(config[:volume]).each { |vol| cmd << " -v #{vol}" }
        Array(config[:link]).each { |link| cmd << " --link #{link}" }
        cmd << " #{image} #{config[:command]}"
      end

      def docker_exec_command(container_id, cmd, opt = {})
        exec_cmd = "exec"
        exec_cmd << " -t" if opt[:tty]
        exec_cmd << " -i" if opt[:interactive]
        # exec_cmd << " <<-EOH\n#{cmd}\nEOH"
        exec_cmd << " #{container_id} #{cmd}"
      end

      def docker_pre_transfer_command(provisioner, container_id)
        cmd = "mkdir -p #{provisioner[:root_path]}"
        cmd << " && rm -rf #{provisioner[:root_path]}/*"
        docker_exec_command(container_id, cmd)
      end

      def docker_transfer_command(provisioner, container_id)
        remote_cmd = "tar x -C #{provisioner[:root_path]}"
        local_cmd  = "cd #{provisioner.sandbox_path} && tar cf - ./"
        "#{local_cmd} | #{docker_command(docker_exec_command(container_id, remote_cmd, :interactive => true))}"
      end

      def parse_image_id(output)
        unless output.chomp.match(/Successfully built ([0-9a-z]{12})$/)
          raise ActionFailed, 'Could not parse IMAGE ID.'
        end
        $1
      end

      def parse_container_id(output)
        unless output.chomp.match(/([0-9a-z]{64})$/)
          raise ActionFailed, 'Could not parse CONTAINER ID.'
        end
        $1
      end

      def docker_file
        if config[:dockerfile]
          file = IO.read(File.expand_path(config[:dockerfile]))
        else
          file = ["FROM #{config[:image]}"]
          case config[:platform]
          when 'debian', 'ubuntu'
            file << 'RUN apt-get update'
            file << 'RUN apt-get -y install sudo curl tar'
          when 'rhel', 'centos'
            file << 'RUN yum clean all'
            file << 'RUN yum -y install sudo curl tar'
          else
            # TODO: Support other distribution
          end
          Array(config[:run_command]).each { |cmd| file << "RUN #{cmd}" }
          Array(config[:environment]).each { |env, value| file << "ENV #{env}=#{value}" }
          file.join("\n")
        end
      end

      def execute(cmd, opts = {})
        run_command(docker_command(cmd), opts)
      end


    end
  end
end
