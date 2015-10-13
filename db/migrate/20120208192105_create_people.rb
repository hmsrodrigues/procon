require 'ae_users_migrator/import'

class CreatePeople < ActiveRecord::Migration
  class ProconProfile < ActiveRecord::Base
  end
  
  class Permission < ActiveRecord::Base
  end
  
  def self.up
    create_table :people, :force => true do |t|
      t.string :email
      t.string :firstname
      t.string :lastname
      t.string :gender
      t.string :profile_gender
      t.timestamp :birthdate
      
      t.string :nickname
      t.string :phone
      t.string :best_call_time
      t.boolean :admin

      t.cas_authenticatable
      t.trackable
      t.timestamps
    end

    add_index :people, :username, :unique => true
    
    person_ids = Attendance.all(:group => :person_id, :select => :person_id).map(&:person_id)
    person_ids += ProconProfile.all(:group => :person_id, :select => :person_id).map(&:person_id) if ProconProfile.connection.tables.include?(ProconProfile.table_name)
    person_ids += Permission.all(:group => :person_id, :select => :person_id).map(&:person_id) if Permission.connection.tables.include?(Permission.table_name)
    
    # Event schema has changed to the point of unusability here, we have to use SQL
    person_ids += execute("select distinct proposer_id from #{Event.table_name}").map { |r| r[0] }
    person_ids = person_ids.uniq.compact
    
    role_ids = []
    role_ids += Permission.group(:role_id).map(&:role_id) if Permission.connection.tables.include?(Permission.table_name)
    role_ids = role_ids.uniq.compact
    
    if person_ids.count > 0 or role_ids.count > 0
      unless File.exist?("ae_users.json")
        raise "There are users to migrate, and ae_users.json does not exist.  Please use export_ae_users.rb to create it."
      end
      dumpfile = AeUsersMigrator::Import::Dumpfile.load(File.new("ae_users.json"))

      merged_person_ids = {}
            
      role_ids.each do |role_id|
        person_ids += dumpfile.roles[role_id].people.map(&:id)
      end
      person_ids = person_ids.uniq.compact
      
      say "Migrating #{person_ids.size} existing people from ae_users"
      
      person_ids.each do |person_id|
        person = dumpfile.people[person_id]
        if person.nil?
          say "Person ID #{person_id.inspect} not found in ae_users.json!  Dangling references may be left in database."
          next
        end
        
        if person.primary_email_address.nil?
          say "Person ID #{person.id} (#{person.firstname} #{person.lastname}) has no primary email address!  Cannot create, so dangling references may be left in database."
          next
        end
        
        merge_into = Person.find_by_username(person.primary_email_address.address)
        if merge_into.nil?
          merge_into = Person.new(:firstname => person.firstname, :lastname => person.lastname, 
            :email => person.primary_email_address.address, :gender => person.gender, :profile_gender => person.gender,
            :birthdate => person.birthdate, :username => person.primary_email_address.address)
          merge_into.id = person.id
        else
          say "Person ID #{person.id} (#{person.firstname} #{person.lastname}) has an existing email address.  Merging into ID #{merge_into.id} (#{person.firstname} #{person.lastname})."
          merged_person_ids[person.id] = merge_into.id
        end
        
        begin
          profile = ProconProfile.first(:conditions => {:person_id => person.id})
          if profile
            merge_into.nickname = profile.nickname
            merge_into.best_call_time = profile.best_call_time
            merge_into.phone = profile.phone
          end
        rescue ActiveRecord::StatementInvalid
          # procon_profiles doesn't exist, forget it
        end
        merge_into.save!
      end
      
      merged_person_ids.each do |from_id, to_id|
        merge_into = Person.find(to_id)
        count = merge_into.merge_person_id!(from_id)
        say "Merged #{count} existing records for person ID #{from_id}"
      end
      
      if Permission.connection.tables.include?(Permission.table_name)
        Permission.all(:conditions => "permission is null and permissioned_id is null").each do |perm|
          say "Found admin permission #{perm.inspect}"
        
          admins = []
          if perm.person_id
            if merged_person_ids[perm.person_id]
              admins << Person.find(merged_person_ids[perm.person_id])
            else
              admins << Person.find(perm.person_id)
            end
          elsif perm.role_id
            admins += Person.all(:conditions => {:id => dumpfile.roles[perm.role_id].people.map(&:id)})
          end
        
          admins.each do |person|
            say "Granting admin rights to #{person.name}"
            person.admin = true
            person.save!
          end
        end

        drop_table :permissions
      end
      
      drop_table :open_id_authentication_associations
      drop_table :open_id_authentication_nonces
      drop_table :permission_caches
      drop_table :procon_profiles if ProconProfile.connection.tables.include?(ProconProfile.table_name)
      drop_table :auth_tickets
    end
  end

  def self.down
    raise ActiveRecord::IrreversibleMigration
  end
end