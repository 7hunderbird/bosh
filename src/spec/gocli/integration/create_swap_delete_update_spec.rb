require_relative '../spec_helper'
require 'fileutils'

RSpec::Matchers.define :be_create_swap_deleted do |old_vm|
  match do |new_vm|
    new_vm['active'] == 'true' &&
      new_vm['az'] == old_vm['az'] &&
      new_vm['vm_type'] == old_vm['vm_type'] &&
      new_vm['instance'] == old_vm['instance'] &&
      new_vm['process_state'] == 'running' &&
      new_vm['vm_cid'] != old_vm['vm_cid'] &&
      new_vm['ips'] != old_vm['ips']
  end
end

describe 'deploy with create-swap-delete', type: :integration do
  with_reset_sandbox_before_each

  let(:manifest) do
    manifest = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups(instances: 1, azs: ['z1'])
    manifest['update'] = manifest['update'].merge('vm_strategy' => 'create-swap-delete')
    manifest
  end

  let(:cloud_config) do
    cloud_config = Bosh::Spec::NewDeployments.simple_cloud_config_with_multiple_azs
    cloud_config['networks'][0]['type'] = network_type
    cloud_config
  end

  let(:network_type) { 'dynamic' }

  context 'a very simple deploy' do
    instance_slug_regex = %r/foobar\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/

    before do
      deploy_from_scratch(manifest_hash: manifest, cloud_config_hash: cloud_config)
    end

    it 'should create vms that require recreation and download packages to them before updating' do
      deploy_simple_manifest(manifest_hash: manifest, recreate: true)
      output = bosh_runner.run('task 4')

      expect(output)
        .to match(%r{Creating missing vms: foobar\/.*\n.*Downloading packages: foobar.*\n.*Updating instance foobar})
    end

    it 'should show new vms in bosh vms command' do
      old_vm = table(bosh_runner.run('vms', json: true))[0]

      original_vm = table(bosh_runner.run('vms', json: true))[0]

      deploy_simple_manifest(manifest_hash: manifest, recreate: true)
      vms = table(bosh_runner.run('vms', json: true))

      expect(vms.length).to eq(1)

      vm_pattern = {
        'active' => /true|false/,
        'az' => 'z1',
        'instance' => instance_slug_regex,
        'ips' => /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/,
        'process_state' => /[a-z]{7}/,
        'vm_cid' => /[0-9]{1,6}/,
        'vm_type' => 'a',
      }

      new_vm = vms[0]

      expect(new_vm).to match(vm_pattern)

      expect(new_vm).to be_create_swap_deleted(old_vm)

      orphaned_vms = table(bosh_runner.run('orphaned-vms', json: true))
      expect(orphaned_vms.length).to eq(1)

      orphaned_vm = orphaned_vms[0]
      expect(orphaned_vm).to match(
        'az' => 'z1',
        'deployment' => manifest['name'],
        'instance' => original_vm['instance'],
        'ips' => '',
        'vm_cid' => original_vm['vm_cid'],
        'orphaned_at' => /.*/,
      )
      expect(Time.parse(orphaned_vm['orphaned_at'])).to be_within(5.minutes).of(Time.now)
    end

    it 'should show the new vm only in bosh instances command' do
      # get original vm info
      instances = table(bosh_runner.run('instances', json: true))

      expect(instances.length).to eq(1)
      original_instance = instances[0]

      expect(original_instance).to match(
        'az' => 'z1',
        'instance' => %r|foobar/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}|,
        'ips' => /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/,
        'deployment' => 'simple',
        'process_state' => 'running',
      )

      deploy_simple_manifest(manifest_hash: manifest, recreate: true)

      # get new vm info
      # assert it is different
      new_instances = table(bosh_runner.run('instances', json: true))

      expect(new_instances.length).to eq(1)
      new_instance = new_instances[0]
      expect(new_instance).to_not eq original_instance
    end

    it 'should run software on the newly created vm' do
      manifest['instance_groups'].first['jobs'].first['properties'] = { 'test_property' => 1 }
      deploy_simple_manifest(manifest_hash: manifest, recreate: true)

      foobar_instance = director.instance('foobar', '0')

      template = foobar_instance.read_job_template('foobar', 'bin/foobar_ctl')
      expect(template).to include('test_property=1')
    end

    context 'when using instances with persistent disk' do
      before do
        manifest['instance_groups'][0]['persistent_disk'] = 1000
        deploy_simple_manifest(manifest_hash: manifest)
      end

      it 'should attach disks to new create-swap-deleted vms' do
        instance = director.instances.first
        disk_cid = instance.disk_cids[0]
        expect(disk_cid).not_to be_empty

        expect(current_sandbox.cpi.disk_attached_to_vm?(instance.vm_cid, disk_cid)).to eq(true)

        director.start_recording_nats
        deploy_simple_manifest(manifest_hash: manifest, recreate: true)

        instance = director.instances.first
        expect(current_sandbox.cpi.disk_attached_to_vm?(instance.vm_cid, disk_cid)).to eq(true)
        nats_messages = extract_agent_messages(director.finish_recording_nats, instance.agent_id)
        expect(nats_messages).to include('mount_disk')
      end
    end

    context 'when adding an additional network to VM' do
      let(:network_type) { 'manual' }

      it 'create-swap-deleted vms' do
        old_vm = table(bosh_runner.run('vms', json: true))[0]

        cloud_config['networks'] << {
          'name' => 'crazy-train',
          'type' => 'manual',
          'subnets' => [
            {
              'range' => '10.0.1.0/24',
              'gateway' => '10.0.1.1',
              'dns' => ['10.0.1.1', '10.0.1.2'],
              'static' => [],
              'reserved' => [],
              'cloud_properties' => {},
              'az' => 'z1',
            },
          ],
        }
        upload_cloud_config(cloud_config_hash: cloud_config)
        manifest['instance_groups'][0]['networks'][0]['default'] = %w[dns gateway]
        manifest['instance_groups'][0]['networks'] << { 'name' => 'crazy-train' }

        original_vm = table(bosh_runner.run('vms', json: true))[0]

        out = deploy_simple_manifest(manifest_hash: manifest)
        expect(out).to match(/Creating missing vms: foobar/)
        expect(out).to match(/Downloading packages: foobar/)

        vms = table(bosh_runner.run('vms', json: true))

        expect(vms.length).to eq(1)

        vm_pattern = {
          'active' => /true|false/,
          'az' => 'z1',
          'instance' => instance_slug_regex,
          'ips' => /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/,
          'process_state' => /[a-z]{7}/,
          'vm_cid' => /[0-9]{1,6}/,
          'vm_type' => 'a',
        }

        new_vm = vms[0]

        expect(new_vm).to match(vm_pattern)
        expect(new_vm).to be_create_swap_deleted(old_vm)

        orphaned_vms = table(bosh_runner.run('orphaned-vms', json: true))
        expect(orphaned_vms.length).to eq(1)

        orphaned_vm = orphaned_vms[0]
        expect(orphaned_vm).to match(
          'az' => 'z1',
          'deployment' => manifest['name'],
          'instance' => original_vm['instance'],
          'ips' => original_vm['ips'],
          'vm_cid' => original_vm['vm_cid'],
          'orphaned_at' => /.*/,
        )
        expect(Time.parse(orphaned_vm['orphaned_at'])).to be_within(5.minutes).of(Time.now)
      end
    end

    context 'when changing network settings' do
      let(:network_type) { 'manual' }

      it 'be_create_swap_deleted vms' do
        old_vm = table(bosh_runner.run('vms', json: true))[0]

        cloud_config['networks'][0]['subnets'][0]['reserved'] << old_vm['ips']
        upload_cloud_config(cloud_config_hash: cloud_config)
        out = deploy_simple_manifest(manifest_hash: manifest)
        expect(out).to match(/Creating missing vms: foobar/)
        expect(out).to match(/Downloading packages: foobar/)

        vms = table(bosh_runner.run('vms', json: true))

        expect(vms.length).to eq(1)

        vm_pattern = {
          'active' => /true|false/,
          'az' => 'z1',
          'instance' => instance_slug_regex,
          'ips' => /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/,
          'process_state' => /[a-z]{7}/,
          'vm_cid' => /[0-9]{1,6}/,
          'vm_type' => 'a',
        }

        new_vm = vms[0]

        expect(new_vm).to match(vm_pattern)

        expect(new_vm).to be_create_swap_deleted(old_vm)
      end
    end

    context 'when the instance is on a manual network' do
      let(:network_type) { 'manual' }

      it 'should show new vms in bosh vms command' do
        old_vm = table(bosh_runner.run('vms', json: true))[0]

        deploy_simple_manifest(manifest_hash: manifest, recreate: true)
        vms = table(bosh_runner.run('vms', json: true))

        expect(vms.length).to eq(1)

        vm_pattern = {
          'active' => /true|false/,
          'az' => 'z1',
          'instance' => instance_slug_regex,
          'ips' => /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/,
          'process_state' => /[a-z]{7}/,
          'vm_cid' => /[0-9]{1,6}/,
          'vm_type' => 'a',
        }

        new_vm = vms[0]

        expect(new_vm).to match(vm_pattern)

        expect(new_vm).to be_create_swap_deleted(old_vm)
      end

      context 'when doing a no-op deploy' do
        it 'should not create new vms' do
          old_vm = table(bosh_runner.run('vms', json: true))[0]

          deploy_simple_manifest(manifest_hash: manifest)
          vms = table(bosh_runner.run('vms', json: true))

          expect(vms.length).to eq(1)

          vm_pattern = {
            'active' => /true|false/,
            'az' => 'z1',
            'instance' => instance_slug_regex,
            'ips' => /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/,
            'process_state' => /[a-z]{7}/,
            'vm_cid' => /[0-9]{1,6}/,
            'vm_type' => 'a',
          }

          new_vm = vms[0]

          expect(new_vm).to match(vm_pattern)

          expect(new_vm).to eq(old_vm)
        end
      end

      context 'when using instances with static ip addresses' do
        before do
          manifest['instance_groups'][0]['networks'][0]['static_ips'] = ['192.168.1.10']
          deploy_simple_manifest(manifest_hash: manifest)
        end

        it 'should not create-swap-deleted vms' do
          task_id = nil
          expect do
            deploy_simple_manifest(manifest_hash: manifest, recreate: true)
            task_id = bosh_runner.get_most_recent_task_id
          end.not_to(change { director.instances.first.ips })

          task_log = bosh_runner.run("task #{task_id} --debug")
          expect(task_log).to match(/Skipping create-swap-delete for static ip enabled instance #{instance_slug_regex}/)
        end
      end
    end
  end

  context 'when running dry run initially' do
    before do
      deploy_from_scratch(
        manifest_hash: manifest,
        cloud_config_hash: cloud_config,
        dry_run: true,
      )
    end

    it 'does not interfere with a successful deployment later' do
      _, exit_code = deploy_from_scratch(
        manifest_hash: manifest,
        cloud_config_hash: cloud_config,
        return_exit_code: true,
      )

      expect(exit_code).to eq(0)
    end
  end
end
