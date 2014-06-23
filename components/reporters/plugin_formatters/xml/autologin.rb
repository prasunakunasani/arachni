=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

class Arachni::Reporters::XML

# XML formatter for the results of the AutoLogin plugin
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
class PluginFormatters::AutoLogin < Arachni::Plugin::Formatter

    def run( xml )
        xml.message results['message']
        xml.status results['status']

        if results['cookies']
            xml.cookies {
                results['cookies'].each { |name, value| xml.cookie name: name, value: value }
            }
        end
    end

end
end
