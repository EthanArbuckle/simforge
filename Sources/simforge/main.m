//
//  main.m
//  simforge
//
//  Created by Ethan Arbuckle on 1/16/25.
//

#import <Foundation/Foundation.h>
#import <dirent.h>
#import <mach-o/loader.h>
#import <sys/stat.h>

bool convert_macho_to_simulator(const char *filepath) {
    FILE *file = fopen(filepath, "r+b");
    if (file == NULL) {
        return false;
    }
    
    struct mach_header_64 header;
    if (fread(&header, sizeof(header), 1, file) != 1) {
        fclose(file);
        return false;
    }
    
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64) {
        fclose(file);
        return false;
    }
    
    bool modified = false;
    uint32_t cmd_offset = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header.ncmds; i++) {
        struct load_command lc;
        fseek(file, cmd_offset, SEEK_SET);
        
        if (fread(&lc, sizeof(struct load_command), 1, file) != 1) {
            printf("Error reading load command: %s\n", filepath);
            fclose(file);
            return false;
        }
        
        if (lc.cmd == LC_BUILD_VERSION) {
            struct build_version_command bvc;
            fseek(file, cmd_offset, SEEK_SET);
            
            if (fread(&bvc, sizeof(struct build_version_command), 1, file) != 1) {
                printf("Error reading build version command: %s\n", filepath);
                fclose(file);
                return false;
            }
            
            bvc.platform = PLATFORM_IOSSIMULATOR;
            bvc.minos = 0x000e0000;
            bvc.sdk = 0x000e0000;
            
            fseek(file, cmd_offset, SEEK_SET);
            if (fwrite(&bvc, sizeof(bvc), 1, file) != 1) {
                printf("Error writing build version command: %s\n", filepath);
                fclose(file);
                return false;
            }
            
            modified = true;
            break;
        }
        cmd_offset += lc.cmdsize;
    }
    
    if (!modified) {
        struct build_version_command bvc = {
            .cmd = LC_BUILD_VERSION,
            .cmdsize = sizeof(struct build_version_command),
            .platform = PLATFORM_IOSSIMULATOR,
            .minos = 0x000e0000,
            .sdk = 0x000e0000,
            .ntools = 0
        };
        
        fseek(file, cmd_offset, SEEK_SET);
        if (fwrite(&bvc, sizeof(bvc), 1, file) != 1) {
            printf("Error adding build version command: %s\n", filepath);
            fclose(file);
            return false;
        }
        
        header.ncmds++;
        header.sizeofcmds += sizeof(bvc);
        
        fseek(file, 0, SEEK_SET);
        if (fwrite(&header, sizeof(header), 1, file) != 1) {
            printf("Error updating header: %s\n", filepath);
            fclose(file);
            return false;
        }
    }
    
    printf("Successfully converted: %s\n", filepath);
    fclose(file);
    return true;
}

void process_bundle_directory(const char *dirpath) {
    DIR *dir = opendir(dirpath);
    if (dir == NULL) {
        return;
    }
    
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        
        char fullpath[4096];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", dirpath, entry->d_name);
        
        struct stat path_stat;
        stat(fullpath, &path_stat);
        
        if (S_ISDIR(path_stat.st_mode)) {
            process_bundle_directory(fullpath);
        }
        else if (S_ISREG(path_stat.st_mode)) {
            convert_macho_to_simulator(fullpath);
        }
    }
    
    closedir(dir);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            printf("Usage: %s <.app bundle>\n", argv[0]);
            return 1;
        }
        
        process_bundle_directory(argv[1]);
        
    }
    return 0;
}
